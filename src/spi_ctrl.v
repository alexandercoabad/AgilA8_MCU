`default_nettype none

// General-purpose SPI master, INTENDED for driving an external SPI slave
// device (an LCD, an ADC, another MCU, etc) - NOT for the flash/PSRAM
// memory devices, which already have their own dedicated controllers.
//
// *** REQUIRES ONE BOARD MODIFICATION - READ BEFORE USING ***
// On the stock Tiny Tapeout QSPI Pmod, CS2 is wired directly to a real,
// populated second PSRAM chip ("RAM B") - not to an external connector
// pin. This peripheral only works once that chip is disabled: per the
// Pmod's own documentation (github.com/mole99/qspi-pmod), each of the
// three chip-select traces can be cut on the back of the board, at
// which point a 1k pull-up disables that chip and the pad becomes
// available via a through-hole header pin as a plain input or output.
// Cutting CS2's trace specifically disables RAM B and frees exactly the
// pin this module needs - this is a documented, intended modification
// on the board as sold, not a custom PCB respin. Flash (CS0) and RAM A
// (CS1) are untouched by this cut, so IMEM/DMEM keep working normally.
//
// Until that trace is cut, this module is functionally inert: CS2
// still selects the live RAM B chip, so every "external" SPI transfer
// this module issues actually talks to that PSRAM using the wrong
// command protocol, and reaches no external device. The RTL itself
// doesn't change based on whether the trace is cut - the requirement is
// physical, not something firmware can work around.
//
// Shares the same physical SD0 (MOSI) / SD1 (MISO) / SCK lines as
// qspi_flash_reader and qspi_psram_ctrl (see tt_um_agila8.v - there are
// no free physical pins left for a genuinely separate bus), using CS2
// as this peripheral's own dedicated chip select once the cut above has
// been made.
//
// CS is auto-managed per transfer (asserted only during the active 8-bit
// shift, deasserted otherwise) - the same pattern qspi_flash_reader.v and
// qspi_psram_ctrl.v already use, and NOT just a style choice. a8_core has
// no instruction cache: every instruction, including the very next DATA
// write in what might look like a logical multi-byte burst, has to be
// fetched from flash first, over this same shared bus. That makes a
// genuinely continuous "hold CS low across several bytes" burst
// impossible on this hardware no matter how CS is managed here - the
// attached device would see real SPI traffic interleaved with unrelated
// flash-fetch clock/data the whole time CS was held. Auto-pulsing per
// byte at least keeps CS deasserted while that flash traffic happens, so
// the attached device correctly ignores it instead of misinterpreting it
// as its own protocol traffic.
//
// Deliberately BLOCKING: a DATA write holds dmem_ready low until the
// full 8-bit transfer physically completes, exactly like flash/PSRAM
// reads already do. This is what keeps the shared-bus sharing in
// tt_um_agila8.v safe: a8_core's own FSM guarantees imem and dmem
// accesses never overlap, but this peripheral's transfers are triggered
// by software, not directly by that FSM. If a DATA write returned
// immediately and shifted the byte out in the background, the CPU could
// go on to fetch its next instruction - or issue a psram access - while
// this transfer is still driving the shared lines, corrupting whichever
// transaction loses the argument. Blocking keeps this peripheral inside
// the same single-active-transaction invariant the rest of the design
// already depends on, for free, with no separate arbitration hardware
// needed.
//
// Mode 0 (CPOL=0, CPHA=0), MSB-first, full-duplex (MOSI shifts out
// while MISO shifts in simultaneously - standard SPI). Uses the same
// pre-shift-by-one-bit load technique as qspi_flash_reader.v and
// qspi_psram_ctrl.v to avoid the off-by-one bit delay bug found and
// fixed in both of those - see either file's header for the full
// explanation of that bug.
//
// Register map (see a8_peripherals.v for how these map into the DMEM
// peripheral window):
//   SPI_DATA (R/W): write shifts the byte out, CS auto-asserted for the
//                   duration (blocking until done, see above); read
//                   returns the byte simultaneously shifted in from
//                   MISO during the most recent transfer, without
//                   starting a new one. To read a byte FROM a slave,
//                   write a dummy byte (0x00) and then read DATA back -
//                   standard full-duplex SPI behavior, not a bug.
//   SPI_CTRL (R/W): bits[1:0] = SCK clock divider select:
//                     00 = fastest  (~sys_clk/2,  matches flash/PSRAM)
//                     01 = ~sys_clk/8
//                     10 = ~sys_clk/32
//                     11 = ~sys_clk/128 (reset default - start slow,
//                          let software speed up once the attached
//                          device is known to tolerate it)


module spi_ctrl (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [7:0] addr,
    input  wire [7:0] wdata,
    input  wire       we,
    input  wire       valid,

    output wire [7:0] rdata,
    output wire        ready,
    output wire        hit,

    // Pmod-facing side (shared bus - see header)
    output wire        cs_n,   // -> uio[7] (CS2, previously unused)
    output wire        sck,
    output wire        mosi,
    input  wire        miso
);

    localparam ADDR_DATA = 8'hF3;
    localparam ADDR_CTRL = 8'hF4;

    assign hit = (addr == ADDR_DATA) || (addr == ADDR_CTRL);

    //------------------------------------------------------------------
    // Clock divider - plain, persistent, software-controlled register,
    // independent of the transfer FSM below.
    //------------------------------------------------------------------

    reg [1:0] div_sel;

    wire [19:0] half_period =
        (div_sel == 2'd0) ? 20'd0   :
        (div_sel == 2'd1) ? 20'd3   :
        (div_sel == 2'd2) ? 20'd15  :
                             20'd63;

    //------------------------------------------------------------------
    // Transfer FSM
    //------------------------------------------------------------------

    localparam S_IDLE = 2'd0;
    localparam S_XFER = 2'd1;
    localparam S_DONE = 2'd2;

    reg [1:0]  state;
    reg [7:0]  sh;
    reg [2:0]  bitcnt;    // 0..7
    reg        phase;
    reg [19:0] div_cnt;

    reg        cs_n_r, sck_r, mosi_r, ready_r;
    reg        just_finished; // same valid/ready race guard used in
                                // qspi_flash_reader.v / qspi_psram_ctrl.v

    assign cs_n  = cs_n_r;
    assign sck   = sck_r;
    assign mosi  = mosi_r;
    assign ready = ready_r;
    // sh already holds the correct fully-shifted-in byte the moment the
    // last bit's high phase completes (same reasoning as
    // qspi_psram_ctrl.v's `assign rdata = sh[7:0];`) - no separate
    // latch needed, and re-capturing another bit from miso in S_DONE
    // would just shift in a spurious 9th bit and corrupt it.
    //
    // Per-address mux: a CTRL read must return div_sel, not whatever's
    // left over in the SPI shift register from the last transfer.
    assign rdata = (addr == ADDR_CTRL) ? {6'b0, div_sel} : sh;

    wire        phase_done = (div_cnt >= half_period) || (half_period == 20'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            cs_n_r        <= 1'b1;
            sck_r         <= 1'b0;
            mosi_r        <= 1'b0;
            ready_r       <= 1'b0;
            bitcnt        <= 3'd0;
            phase         <= 1'b0;
            div_cnt       <= 20'd0;
            sh            <= 8'd0;
            just_finished <= 1'b0;
            div_sel       <= 2'd3; // slowest, safest default
        end else begin
            ready_r       <= 1'b0;
            just_finished <= (state == S_DONE);

            // CTRL is a plain register, always live, independent of the
            // transfer FSM. Safe to write any time: a8_core can only be
            // touching one address on this bus at a time, and it can't
            // issue a new dmem access while a DATA transfer still has
            // dmem_ready withheld (see header) - so this never overlaps
            // an in-progress transfer in practice.
            if (valid && we && addr == ADDR_CTRL)
                div_sel <= wdata[1:0];

            if (valid && addr == ADDR_CTRL)
                ready_r <= 1'b1;

            case (state)
                S_IDLE: begin
                    cs_n_r  <= 1'b1;
                    sck_r   <= 1'b0;
                    div_cnt <= 20'd0;
                    if (valid && addr == ADDR_DATA && !just_finished) begin
                        if (we) begin
                            // Pre-shift by one bit to compensate for the
                            // hardcoded first-bit mosi_r assignment
                            // below - see qspi_flash_reader.v /
                            // qspi_psram_ctrl.v headers for why this is
                            // needed.
                            sh     <= wdata << 1;
                            mosi_r <= wdata[7];
                            cs_n_r <= 1'b0;
                            bitcnt <= 3'd0;
                            phase  <= 1'b0;
                            state  <= S_XFER;
                        end else begin
                            // Plain read of DATA: just return the byte
                            // from the last transfer (sh, via the rdata
                            // mux above) immediately - do NOT assert CS
                            // or kick off a new hardware transfer just
                            // because the address was read.
                            ready_r <= 1'b1;
                        end
                    end
                end

                S_XFER: begin
                    if (!phase_done) begin
                        div_cnt <= div_cnt + 20'd1;
                    end else begin
                        div_cnt <= 20'd0;
                        if (!phase) begin
                            // Low phase elapsed - rising edge now. MOSI
                            // already stable since the previous falling
                            // edge (or the initial load).
                            sck_r <= 1'b1;
                            phase <= 1'b1;
                        end else begin
                            // High phase elapsed - this is the sample
                            // point for MISO (mode 0: sample on the
                            // rising edge's settled level, capture here
                            // at the falling edge just like flash/PSRAM
                            // do for reads).
                            sh     <= {sh[6:0], miso};
                            mosi_r <= sh[7];
                            sck_r  <= 1'b0;
                            phase  <= 1'b0;
                            if (bitcnt == 3'd7) begin
                                state <= S_DONE;
                            end else begin
                                bitcnt <= bitcnt + 3'd1;
                            end
                        end
                    end
                end

                S_DONE: begin
                    cs_n_r  <= 1'b1;
                    sck_r   <= 1'b0;
                    ready_r <= 1'b1;
                    state   <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
