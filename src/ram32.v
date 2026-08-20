`default_nettype none

// On-chip RAM32 (128 bytes, DMEM 0x00-0x7F). Plain inferred synchronous
// RAM - `reg [7:0] mem [0:127];` is ordinary synthesizable logic that
// most flows map onto a small number of standard SRAM/register-bank
// cells appropriate to its size; this is NOT wired as, nor does it
// assume, a specific hard macro. If a specific RAM32 hard-macro
// black-box (with its own fixed port list/timing) is the actual target
// here, this module's internals would need to change to instantiate
// that macro directly - the external port contract below (matching
// every other dmem-style front-end in this design: addr/wdata/we/valid
// /rdata/ready) would stay the same either way, so nothing upstream in
// tt_um_agila8.v needs to change if that swap happens later.
//
// 1-cycle read/write latency (valid this cycle -> ready+rdata, or the
// write committed, next cycle) - matches every other dmem-style
// front-end in this design (a8_peripherals.v, qspi_shared_engine.v's
// psram front-end).

module ram32 (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [7:0] addr,   // only bits [6:0] are meaningful (0x00-0x7F)
    input  wire [7:0] wdata,
    input  wire       we,
    input  wire       valid,

    output reg  [7:0] rdata,
    output reg        ready
);

    reg [7:0] mem [0:127];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ready <= 1'b0;
            rdata <= 8'h00;
        end else begin
            ready <= valid;
            if (valid) begin
                if (we)
                    mem[addr[6:0]] <= wdata;
                else
                    rdata <= mem[addr[6:0]];
            end
        end
    end

endmodule
