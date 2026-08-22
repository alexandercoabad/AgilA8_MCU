`default_nettype none

// On-chip writable instruction RAM - IMEM 0x0080-0x00FF (128 bytes).
// This is what boot_rom.v's bootloader routine writes a received
// program into, and what it then jumps to - see build_boot_rom.py's
// docstring for the wire protocol. Read via the normal imem bus like
// every other IMEM front-end; written via two DMEM-mapped registers
// (IMEM_WADDR / IMEM_WDATA below), since the imem port itself is
// read-only from the CPU's perspective, same as real flash would be.
//
// UNINITIALIZED ON RESET, LIKE ram32.v: this is a plain flip-flop
// array, not a macro with a defined power-on state. If the CPU somehow
// reaches an address in this range before the bootloader (or anything
// else) has written real content there, it executes whatever garbage
// synthesis/PnR happened to leave behind - same caveat ram32.v already
// documents for DMEM, now also true for this IMEM range. In practice
// this shouldn't happen: boot_rom.v never jumps into 0x80-0xFF until
// after the bootloader has finished writing it (see LOAD_DONE), and
// the timeout fallback path jumps straight to flash (0x0100+) instead,
// never touching this range at all.
//
// Register map (DMEM-mapped, decoded here directly rather than folded
// into a8_peripherals.v - this crosses between the DMEM bus and the
// IMEM array, which is a different kind of thing than a8_peripherals.v's
// GPIO/timer/PWM registers, so it gets its own module):
//   IMEM_WADDR (W): sets the write pointer (0-127, low 7 bits used).
//                   Read returns the current pointer value.
//   IMEM_WDATA (W): commits wdata to mem[pointer], then increments the
//                   pointer. Read is not meaningful (returns 0) - this
//                   is a write-triggered action, not a plain register.

module iram (
    input  wire       clk,
    input  wire       rst_n,

    // ---- IMEM read port (imem-style, matches boot_rom.v / the rest
    //      of this design's memory front-ends) ----
    input  wire [6:0] imem_addr,
    input  wire       imem_valid,
    output reg  [7:0] imem_rdata,
    output reg        imem_ready,

    // ---- DMEM write-control port (dmem-style, matches every
    //      peripheral in this design: addr/wdata/we/valid -> rdata/
    //      ready/hit) ----
    input  wire [7:0] dmem_addr,
    input  wire [7:0] dmem_wdata,
    input  wire       dmem_we,
    input  wire       dmem_valid,
    output reg  [7:0] dmem_rdata,
    output reg        dmem_ready,
    output wire       dmem_hit
);

    localparam ADDR_WADDR = 8'hF5;
    localparam ADDR_WDATA = 8'hF6;

    assign dmem_hit = (dmem_addr == ADDR_WADDR) || (dmem_addr == ADDR_WDATA);

    reg [7:0] mem [0:127];
    reg [6:0] waddr;

    // *** BUG FIX (see chat): a8_core holds dmem_valid across TWO
    // cycles for every DMEM access (it re-asserts valid every cycle
    // it's still waiting to observe ready, and - because dmem_ready is
    // itself a registered, one-cycle-later response - that means valid
    // is seen high for exactly 2 cycles per instruction, with ready
    // only appearing on the second). That's harmless for ram32.v and
    // a8_peripherals.v, because a plain register write is idempotent:
    // writing the same address with the same data twice in a row
    // leaves the same final result as writing it once. IMEM_WDATA is
    // NOT idempotent - it auto-increments waddr as a side effect of
    // the write - so firing on both qualifying cycles silently wrote
    // every received byte to TWO consecutive addresses instead of one,
    // confirmed by tracing dmem_valid/waddr/dmem_wdata directly: every
    // byte appeared at both waddr and waddr+1 before the next byte's
    // write began. Fixed with an edge-detect guard so the write+
    // increment only fires on the FIRST cycle of each fresh request,
    // not on every cycle valid happens to still be asserted - same
    // general pattern (suppressing a stale/repeated trigger across a
    // multi-cycle wait) as the just_finished guards already used in
    // qspi_shared_engine.v, just for a side-effecting register instead
    // of an SPI bus grant.
    reg was_wdata_valid;

    // ---- Read port ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            imem_ready <= 1'b0;
            imem_rdata <= 8'h00;
        end else begin
            imem_ready <= imem_valid;
            if (imem_valid)
                imem_rdata <= mem[imem_addr];
        end
    end

    // ---- Write-control port ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            waddr           <= 7'd0;
            dmem_ready      <= 1'b0;
            dmem_rdata      <= 8'h00;
            was_wdata_valid <= 1'b0;
        end else begin
            dmem_ready      <= 1'b0;
            was_wdata_valid <= (dmem_valid && dmem_hit && dmem_addr == ADDR_WDATA);

            if (dmem_valid && dmem_hit) begin
                dmem_ready <= 1'b1;

                case (dmem_addr)
                    ADDR_WADDR: begin
                        if (dmem_we)
                            waddr <= dmem_wdata[6:0];
                        dmem_rdata <= {1'b0, waddr};
                    end

                    ADDR_WDATA: begin
                        if (dmem_we && !was_wdata_valid) begin
                            mem[waddr] <= dmem_wdata;
                            waddr      <= waddr + 7'd1;
                        end
                        dmem_rdata <= 8'h00;
                    end

                    default: dmem_rdata <= 8'h00;
                endcase
            end
        end
    end

endmodule
