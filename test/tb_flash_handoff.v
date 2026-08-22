`default_nettype none
`timescale 1ns/1ps

// Timeout -> FLASH_MODE -> flash handoff test, for the iram.v-based
// design (not the shared_ram lineage). No START is asserted, so
// boot_rom's WAIT_START loop times out, sets FLASH_MODE (0xF7), and
// JALRs to imem 0x0080 - which should now resolve to flash byte 0
// (flash_addr = imem_addr - 0x0080), not flash byte 0x80 or an
// underflowed garbage offset. Flash model copied verbatim from the
// shared_ram lineage's tb_regression.v (already verified correct
// there) rather than reinvented.

module tb_flash_handoff;

    reg clk = 0;
    always #10 clk = ~clk;
    reg rst_n = 0;

    reg  [7:0] ui_in = 8'h00;
    wire [7:0] uo_out;
    reg  [7:0] uio_in = 8'h00;
    wire [7:0] uio_out, uio_oe;

    tt_um_agila8 dut (
        .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in),
        .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(rst_n)
    );

    wire flash_cs_n = uio_out[0];
    wire spi_mosi   = uio_out[1];
    wire spi_sck    = uio_out[3];
    reg  miso;
    always @(*) uio_in[2] = miso;

    // ---- Flash behavioral model (03h read) - verbatim from the
    // shared_ram lineage's tb_regression.v ----
    reg [7:0] fmem [0:511];
    initial $readmemh("imem.hex", fmem);
    reg [30:0] f_sh; reg [5:0] f_cnt; reg [7:0] f_data; reg f_miso;
    always @(posedge spi_sck or posedge flash_cs_n) begin
        if (flash_cs_n) f_cnt <= 0;
        else begin
            if (f_cnt < 32) f_sh <= {f_sh[29:0], spi_mosi};
            if (f_cnt == 31) f_data <= fmem[{f_sh[7:0], spi_mosi}];
            f_cnt <= f_cnt + 1;
        end
    end
    always @(negedge spi_sck or posedge flash_cs_n) begin
        if (flash_cs_n) f_miso <= 0;
        else if (f_cnt >= 32) begin
            case (f_cnt - 32)
                0: f_miso<=f_data[7]; 1: f_miso<=f_data[6]; 2: f_miso<=f_data[5]; 3: f_miso<=f_data[4];
                4: f_miso<=f_data[3]; 5: f_miso<=f_data[2]; 6: f_miso<=f_data[1]; 7: f_miso<=f_data[0];
                default: f_miso <= 0;
            endcase
        end
    end
    always @(*) miso = f_miso;

    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    initial begin
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        // no START ever asserted - forces the timeout path

        fork
            begin
                wait (dut.halted == 1);
                $display("HALTED at cycle %0d", cyc);
            end
            begin
                repeat (400000) @(posedge clk);
                $display("TIMEOUT: never halted (cycle=%0d, pc=0x%04x, state=%0d)",
                          cyc, dut.core.pc, dut.core.state);
            end
        join_any
        disable fork;

        repeat (5) @(posedge clk);
        $display("=== FINAL STATE ===");
        $display("halted=%0d pc=0x%04x", dut.halted, dut.core.pc);
        $display("r4=%0d (expect 31 - loaded from flash byte 0 via ADDI)",
                  dut.core.regfile.regs[4]);
        if (dut.halted && dut.core.pc == 16'h0082 && dut.core.regfile.regs[4] == 31)
            $display("RESULT: PASS - flash_addr correctly resolves imem 0x0080 to flash byte 0");
        else
            $display("RESULT: FAIL");
        $finish;
    end

endmodule
