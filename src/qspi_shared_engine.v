`default_nettype none

// One shared physical SPI shift engine (SCK/MOSI/MISO + 40-bit shift
// register) driving three front-ends: flash (CS0), PSRAM (CS1), and a
// generic SPI peripheral (CS2 - requires cutting the RAM B trace on the
// Pmod first; see spi_ctrl.v's header for the board modification this
// depends on). Replaces qspi_flash_reader.v + qspi_psram_ctrl.v +
// spi_ctrl.v as three separate, near-identical FSMs (each ~78/78/40
// flip-flops) with one shared engine (~85 flip-flops) plus three thin
// front-ends (~15-20 flip-flops each for their own request-latching and,
// for spi_ctrl, its CTRL register and persistent last-received-byte
// latch).
//
// SAFE TO SHARE, NOT REAL ARBITRATION: this relies entirely on
// a8_core's own invariant that imem_valid and dmem_valid are never both
// asserted in the same cycle (S_FETCH_*/S_FETCH_GAP vs S_MEM are
// separate, sequential FSM states), and that dmem-side peripherals are
// mutually exclusive by address decode (periph_hit_comb / spi_hit_comb
// / neither, in tt_um_agila8.v). If a8_core is ever pipelined or
// otherwise changed to overlap accesses, this needs real arbitration,
// not the simple fixed-priority grant used here (flash > psram > spi,
// order is arbitrary since by construction at most one is ever
// requesting at a time).
//
// GENERIC PRE-SHIFT, NO MORE HARDCODED-MSB-IS-0 SPECIAL CASE: the three
// original modules each hardcoded mosi_r<=1'b0 for the first bit,
// valid only because flash's 0x03 and PSRAM's 0x02/0x03 command bytes
// all happen to have MSB=0 - NOT true for spi_ctrl's arbitrary data
// byte. Front-ends here instead left-justify their payload into the
// top of a 40-bit field (tx_word), and the engine always takes the
// actual tx_word[39] as the first bit - correct for every front-end
// uniformly, without needing a per-owner special case. See
// qspi_flash_reader.v's original header (kept alongside this file) for
// the full history of the off-by-one bug this pre-shift technique
// fixes; the technique itself is unchanged, just generalized.
//
// TIMING MARGIN NOTE: the SCK-out -> board -> device -> MISO-in round
// trip margin fix (sampling only on the last cycle of an extended high
// phase, not the edge that raises SCK - see qspi_flash_reader.v's v3
// header) now also applies to the spi_ctrl front-end, which did NOT
// have this protection in the original standalone spi_ctrl.v. That
// module only had it implicitly via its slow reset-default clock
// divider (~sys_clk/128) leaving enough natural margin; at its fastest
// setting (div_sel=00, matching flash/PSRAM's speed) it would have had
// the same zero-margin exposure flash/PSRAM were fixed for. This is a
// deliberate, disclosed behavior change made possible by the merge,
// not an incidental side effect.


module qspi_shared_engine #(
    parameter HALF_PERIOD_CYCLES = 1,   // fixed half-period for flash/PSRAM
    parameter DEFAULT_READ_DELAY = 2    // reset value + spi_ctrl's fixed
                                          // read-delay margin (see above)
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- Flash front-end (imem-style, matches qspi_flash_reader.v) ----
    input  wire [15:0] flash_addr,
    input  wire        flash_valid,
    output wire [7:0]  flash_rdata,
    output reg         flash_ready,
    input  wire [3:0]  flash_read_delay_cfg,

    // ---- PSRAM front-end (dmem-style, matches qspi_psram_ctrl.v) ----
    input  wire [7:0]  psram_addr,
    input  wire [7:0]  psram_wdata,
    input  wire        psram_we,
    input  wire        psram_valid,
    output wire [7:0]  psram_rdata,
    output reg         psram_ready,
    input  wire [3:0]  psram_read_delay_cfg,

    // ---- Generic SPI front-end (dmem-style + hit, matches spi_ctrl.v) -
    input  wire [7:0]  spi_addr,
    input  wire [7:0]  spi_wdata,
    input  wire        spi_we,
    input  wire        spi_valid,
    output reg  [7:0]  spi_rdata,
    output reg         spi_ready,
    output wire        spi_hit,

    // ---- Pmod-facing pins ----
    output wire cs_n_flash, // -> uio[0] (CS0)
    output wire cs_n_psram, // -> uio[6] (CS1)
    output wire cs_n_spi,   // -> uio[7] (CS2)
    output wire sck,
    output wire mosi,
    input  wire miso
);

    localparam CMD_READ  = 8'h03;
    localparam CMD_WRITE = 8'h02;

    localparam OWNER_FLASH = 2'd0;
    localparam OWNER_PSRAM = 2'd1;
    localparam OWNER_SPI   = 2'd2;

    //------------------------------------------------------------------
    // spi_ctrl front-end: CTRL register + hit decode + persistent
    // last-received-byte latch. Entirely local state, unaffected by
    // sharing the underlying engine - except spi_last_rx below, which
    // exists *because* of the sharing (sh gets clobbered by whichever
    // front-end uses the engine next, e.g. every single instruction
    // fetch, so spi_ctrl's "plain read of DATA returns the last
    // transfer's byte without retriggering hardware" behavior needs its
    // own persistent copy rather than reading the shared sh directly).
    //------------------------------------------------------------------

    localparam ADDR_DATA = 8'hF3;
    localparam ADDR_CTRL = 8'hF4;

    assign spi_hit = (spi_addr == ADDR_DATA) || (spi_addr == ADDR_CTRL);

    reg [1:0] div_sel;
    reg [7:0] spi_last_rx;

    wire [19:0] spi_half_period =
        (div_sel == 2'd0) ? 20'd1   :  // matches flash/PSRAM's fastest
        (div_sel == 2'd1) ? 20'd4   :
        (div_sel == 2'd2) ? 20'd16  :
                             20'd64;
    // (values are +1 vs spi_ctrl.v's originals since this engine's
    // low_target/high_target comparison convention takes half_period
    // directly rather than as "extra cycles beyond 1", see phase_done
    // below - same real timing, different constant encoding)

    //------------------------------------------------------------------
    // Shared engine state
    //------------------------------------------------------------------

    localparam S_IDLE = 2'd0;
    localparam S_XFER = 2'd1;
    localparam S_DONE = 2'd2;

    reg [1:0]  state;
    reg [39:0] sh;
    reg [5:0]  bitcnt;
    reg [5:0]  bit_len_r;     // 40 for flash/psram, 8 for spi - latched
                                // per-transfer so mid-transfer changes
                                // to what owner "would" request can't
                                // corrupt an in-flight transfer
    reg        phase;
    reg [19:0] div_cnt;
    reg [19:0] half_period_r;
    reg [3:0]  read_delay_r;
    reg [1:0]  owner_r;

    reg        cs_active_r, sck_r, mosi_r;

    assign sck  = sck_r;
    assign mosi = mosi_r;

    assign cs_n_flash = !(cs_active_r && owner_r == OWNER_FLASH);
    assign cs_n_psram = !(cs_active_r && owner_r == OWNER_PSRAM);
    assign cs_n_spi   = !(cs_active_r && owner_r == OWNER_SPI);

    // Flash/PSRAM consumers sample rdata in lockstep with the same-cycle
    // ready pulse (see a8_core.v: `if (imem_ready) instr_hi<=imem_rdata`
    // - both happen off the same registered edge), so a direct
    // combinational read of sh is correct and needs no separate latch,
    // exactly as in the original standalone modules.
    assign flash_rdata = sh[7:0];
    assign psram_rdata = sh[7:0];

    //------------------------------------------------------------------
    // Per-front-end "just finished" guards (same valid/ready race fix
    // as the original modules - see qspi_flash_reader.v's header - now
    // tracked per-owner against the shared done pulse instead of each
    // having a private state==S_DONE check).
    //------------------------------------------------------------------

    reg just_finished_flash, just_finished_psram, just_finished_spi;

    wire done = (state == S_XFER) && phase && phase_done && (bitcnt == bit_len_r - 6'd1);

    // *** Bug fix (see chat): the guard must track state==S_DONE
    // directly, not `done`. `done` is combinationally true one cycle
    // BEFORE state actually becomes S_DONE (it fires during S_XFER's
    // last bit, the same edge that schedules the S_DONE transition) -
    // using it here cleared the guard one full cycle too early, exactly
    // the same cycle `*_ready` first becomes visible to the requesting
    // front-end. That let a still-stale `valid` (the core hasn't had a
    // chance to drop it yet - same turnaround-latency reasoning as
    // qspi_flash_reader.v's header) immediately trigger a NEW transfer
    // using the OLD, not-yet-updated address - confirmed empirically:
    // `accept` was already 1 on the exact same cycle `flash_ready` first
    // pulsed. The original qspi_flash_reader.v got this right with
    // `just_finished <= (state == S_DONE);` - this restores that exact
    // timing, per-owner.
    wire in_done_state = (state == S_DONE);

    // (done is also used below to select which owner is completing, so
    // it stays defined above - just no longer drives the guards.)

    wire flash_want = flash_valid && !just_finished_flash;
    wire psram_want = psram_valid && !just_finished_psram;
    wire spi_want    = spi_valid && spi_hit && (spi_addr == ADDR_DATA)
                        && spi_we && !just_finished_spi;

    wire engine_idle = (state == S_IDLE);
    wire accept      = engine_idle && (flash_want || psram_want || spi_want);

    // Fixed priority: flash > psram > spi. Arbitrary - by construction
    // (a8_core's single-active-transaction invariant, see header) at
    // most one of these is ever actually asserted at once.
    wire [1:0]  grant_owner  = flash_want ? OWNER_FLASH :
                                psram_want ? OWNER_PSRAM : OWNER_SPI;
    wire [39:0] grant_txword = flash_want ? {CMD_READ, 8'h00, flash_addr, 8'h00} :
                                psram_want ? ((psram_we ? {CMD_WRITE, 16'h0000, psram_addr, psram_wdata}
                                                          : {CMD_READ,  16'h0000, psram_addr, 8'h00}))
                                            : {spi_wdata, 32'h0};
    wire [5:0]  grant_len    = (flash_want || psram_want) ? 6'd40 : 6'd8;
    wire [3:0]  grant_rdly   = flash_want ? flash_read_delay_cfg :
                                psram_want ? psram_read_delay_cfg
                                            : DEFAULT_READ_DELAY[3:0];
    wire [19:0] grant_hperiod = (flash_want || psram_want) ? HALF_PERIOD_CYCLES[19:0]
                                                              : spi_half_period;

    wire [19:0] low_target   = half_period_r;
    wire [19:0] high_target  = half_period_r + {16'd0, read_delay_r};
    wire [19:0] phase_target = phase ? high_target : low_target;
    wire        phase_done   = (div_cnt >= phase_target - 20'd1) || (phase_target <= 20'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            cs_active_r   <= 1'b0;
            sck_r         <= 1'b0;
            mosi_r        <= 1'b0;
            bitcnt        <= 6'd0;
            bit_len_r     <= 6'd40;
            phase         <= 1'b0;
            div_cnt       <= 20'd0;
            sh            <= 40'd0;
            half_period_r <= HALF_PERIOD_CYCLES[19:0];
            read_delay_r  <= DEFAULT_READ_DELAY[3:0];
            owner_r       <= OWNER_FLASH;

            flash_ready   <= 1'b0;
            psram_ready   <= 1'b0;
            spi_ready     <= 1'b0;
            spi_rdata     <= 8'h00;

            just_finished_flash <= 1'b0;
            just_finished_psram <= 1'b0;
            just_finished_spi   <= 1'b0;

            div_sel       <= 2'd3; // slowest, safest default (spi_ctrl.v parity)
            spi_last_rx   <= 8'h00;
        end else begin
            flash_ready <= 1'b0;
            psram_ready <= 1'b0;
            spi_ready   <= 1'b0;

            just_finished_flash <= in_done_state && (owner_r == OWNER_FLASH);
            just_finished_psram <= in_done_state && (owner_r == OWNER_PSRAM);
            just_finished_spi   <= in_done_state && (owner_r == OWNER_SPI);

            // spi_ctrl's CTRL register - plain, always-live, independent
            // of the transfer FSM (same reasoning as spi_ctrl.v).
            if (spi_valid && spi_we && spi_addr == ADDR_CTRL)
                div_sel <= spi_wdata[1:0];
            if (spi_valid && spi_addr == ADDR_CTRL)
                spi_ready <= 1'b1;

            // spi_ctrl's plain read of DATA (no we): return the last
            // received byte immediately, no hardware transfer.
            if (spi_valid && spi_hit && spi_addr == ADDR_DATA && !spi_we
                && !just_finished_spi)
                spi_ready <= 1'b1;

            spi_rdata <= (spi_addr == ADDR_CTRL) ? {6'b0, div_sel} : spi_last_rx;

            case (state)
                S_IDLE: begin
                    cs_active_r <= 1'b0;
                    sck_r       <= 1'b0;
                    div_cnt     <= 20'd0;
                    if (accept) begin
                        // Pre-shift by one bit - see header. tx_word is
                        // left-justified by every front-end, so the
                        // actual top bit (whatever it is) becomes the
                        // first output bit, no hardcoded-0 assumption.
                        sh            <= grant_txword << 1;
                        mosi_r        <= grant_txword[39];
                        cs_active_r   <= 1'b1;
                        owner_r       <= grant_owner;
                        bit_len_r     <= grant_len;
                        read_delay_r  <= grant_rdly;
                        half_period_r <= grant_hperiod;
                        bitcnt        <= 6'd0;
                        phase         <= 1'b0;
                        state         <= S_XFER;
                    end
                end

                S_XFER: begin
                    if (!phase_done) begin
                        div_cnt <= div_cnt + 20'd1;
                    end else begin
                        div_cnt <= 20'd0;
                        if (!phase) begin
                            sck_r <= 1'b1;
                            phase <= 1'b1;
                        end else begin
                            sh     <= {sh[38:0], miso};
                            mosi_r <= sh[39];
                            sck_r  <= 1'b0;
                            phase  <= 1'b0;
                            if (bitcnt == bit_len_r - 6'd1) begin
                                state <= S_DONE;
                            end else begin
                                bitcnt <= bitcnt + 6'd1;
                            end
                        end
                    end
                end

                S_DONE: begin
                    cs_active_r <= 1'b0;
                    sck_r       <= 1'b0;
                    state       <= S_IDLE;
                    case (owner_r)
                        OWNER_FLASH: flash_ready <= 1'b1;
                        OWNER_PSRAM: psram_ready <= 1'b1;
                        OWNER_SPI: begin
                            spi_ready   <= 1'b1;
                            spi_last_rx <= sh[7:0];
                        end
                        default: ;
                    endcase
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
