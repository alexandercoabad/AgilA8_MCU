`default_nettype none
`timescale 1ns/1ps

module tb_debug5;
    reg clk = 0;
    always #10 clk = ~clk;
    reg rst_n = 0;

    reg  [7:0] ui_in = 8'h00;
    wire [7:0] uo_out;
    reg  [7:0] uio_in = 8'h00;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;

    tt_um_agila8 dut (
        .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in),
        .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(rst_n)
    );

    localparam HOLD = 150;

    task set_bits(input data, input clock, input start);
        begin
            ui_in[0] = data;
            ui_in[1] = clock;
            ui_in[2] = start;
        end
    endtask

    task send_bit(input b);
        begin
            set_bits(b, 1'b0, 1'b1);
            repeat (HOLD) @(posedge clk);
            set_bits(b, 1'b1, 1'b1);
            repeat (HOLD) @(posedge clk);
            set_bits(b, 1'b0, 1'b1);
            repeat (HOLD) @(posedge clk);
        end
    endtask

    task send_byte(input [7:0] b);
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1)
                send_bit(b[i]);
        end
    endtask

    reg [7:0] prog [0:7];
    initial begin
        prog[0] = 8'h22; prog[1] = 8'h05;
        prog[2] = 8'h24; prog[3] = 8'h03;
        prog[4] = 8'h16; prog[5] = 8'h50;
        prog[6] = 8'hF0; prog[7] = 8'h00;
    end

    // Trace every IMEM_WDATA commit (write to iram.v's mem[]) directly,
    // instead of every PC change - much more targeted for this bug.
    integer cyc = 0;
    always @(posedge clk) begin
        cyc = cyc + 1;
        if (dut.iram_inst.dmem_valid && dut.iram_inst.dmem_hit
            && dut.iram_inst.dmem_we
            && dut.dmem_addr == 8'hF6) begin
            $display("cyc=%0d IMEM_WDATA commit: waddr=%0d wdata=0x%02x  (r3=%0d r5=%0d pc=0x%04x)",
                cyc, dut.iram_inst.waddr, dut.dmem_wdata,
                dut.core.regfile.regs[3], dut.core.regfile.regs[5], dut.core.pc);
        end
        if (cyc > 40000) begin
            $display("STOP at cyc=%0d", cyc);
            $finish;
        end
    end

    integer i;
    initial begin
        rst_n = 0;
        set_bits(1'b0, 1'b0, 1'b0);
        repeat (5) @(posedge clk);
        rst_n = 1;

        repeat (HOLD) @(posedge clk);

        send_byte(8'd8);
        for (i = 0; i < 8; i = i + 1)
            send_byte(prog[i]);

        set_bits(1'b0, 1'b0, 1'b0);

        wait (dut.halted == 1);
        $display("HALTED at cyc=%0d", cyc);
        $finish;
    end
endmodule
