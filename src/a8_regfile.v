`default_nettype none

module a8_regfile (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [2:0] rs1_addr,
    input  wire [2:0] rs2_addr,
    output wire [7:0] rs1_data,
    output wire [7:0] rs2_data,

    input  wire [2:0] rd_addr,
    input  wire [7:0] rd_data,
    input  wire       rd_we
);

    // r0 is not a real flip-flop bank entry - it's hardwired to zero,
    // matching the RISC-V x0 convention. regs[1..7] are real storage.
    reg [7:0] regs [1:7];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 1; i <= 7; i = i + 1)
                regs[i] <= 8'h00;
        end else if (rd_we && rd_addr != 3'd0) begin
            regs[rd_addr] <= rd_data;
        end
    end

    assign rs1_data = (rs1_addr == 3'd0) ? 8'h00 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 3'd0) ? 8'h00 : regs[rs2_addr];

endmodule
