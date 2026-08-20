`default_nettype none

// A8 CPU core.
//
// *** Patched by pre-tapeout simulation review (see /test/TESTING.md) ***
// Two PC-relative address bugs were found and fixed here:
//   1. BEQ/BLT/JAL next_pc computed the signed branch offset as
//      {{8{imm6[5]}}, imm6, 1'b0}, a 15-bit expression. Verilog's
//      context-determined addition then zero-extends (not sign-extends)
//      that 15-bit value to match the 16-bit pc, so any *negative*
//      offset set bit 15 instead of acting as a sign bit - e.g. pc=0x44
//      with offset -6 produced next_pc=0x803e instead of 0x003e. This
//      broke every backward branch/jump (i.e. every loop). Fixed by
//      using 9 copies of the sign bit instead of 8, making the
//      expression a full, self-determined 16 bits so no further
//      extension happens.
//   2. JALR's next_pc <= rs1_data + imm_sext relied on the addition
//      wrapping at 8 bits ("high byte 0" per the original comment), but
//      the same context-determined-addition rule expands both 8-bit
//      operands to 16 bits before adding, so the result isn't clamped
//      to a byte and the high byte can come out nonzero for negative
//      immediates. Fixed by forcing the add to stay 8-bit width and
//      then explicitly zero-extending: {8'h00, rs1_data + imm_sext}.
// Both were confirmed with an Icarus Verilog testbench cross-checked
// against a from-spec Python reference model; see /test/.
//
// Memory interface is deliberately generic/protocol-agnostic - a simple
// valid/ready byte interface - so it can be wired either to:
//   (a) a plain synchronous SRAM/ROM for simulation, or
//   (b) TinyQV's existing, proven QSPI flash + PSRAM controller
//       (https://github.com/MichaelBell/tinyQV) for a real tapeout,
//       which is the recommended path rather than re-deriving untested
//       QSPI timing here.
//
// Instructions are always fetched as two consecutive bytes from IMEM
// (big-endian: high byte at PC, low byte at PC+1). Loads/stores are a
// single byte to/from DMEM's 256-byte window.

module a8_core (
    input  wire        clk,
    input  wire        rst_n,

    // Instruction memory (read-only, byte-wide)
    output reg  [15:0] imem_addr,
    output reg          imem_valid,
    input  wire [7:0]   imem_rdata,
    input  wire          imem_ready,

    // Data memory (read/write, byte-wide, 256-byte window)
    output reg  [7:0]   dmem_addr,
    output reg  [7:0]   dmem_wdata,
    output reg          dmem_we,
    output reg          dmem_valid,
    input  wire [7:0]   dmem_rdata,
    input  wire          dmem_ready,

    output wire         halted
);

    // ------------------------------------------------------------------
    // Opcodes (kept in sync with docs/ISA.md)
    // ------------------------------------------------------------------
    localparam OP_NOP  = 4'h0;
    localparam OP_ADD  = 4'h1;
    localparam OP_ADDI = 4'h2;
    localparam OP_SUB  = 4'h3;
    localparam OP_AND  = 4'h4;
    localparam OP_OR   = 4'h5;
    localparam OP_XOR  = 4'h6;
    localparam OP_SLL  = 4'h7;
    localparam OP_SRL  = 4'h8;
    localparam OP_LW   = 4'h9;
    localparam OP_SW   = 4'hA;
    localparam OP_BEQ  = 4'hB;
    localparam OP_BLT  = 4'hC;
    localparam OP_JAL  = 4'hD;
    localparam OP_JALR = 4'hE;
    localparam OP_HALT = 4'hF;

    // ------------------------------------------------------------------
    // FSM states
    // ------------------------------------------------------------------
    localparam S_RESET    = 3'd0;
    localparam S_FETCH_HI = 3'd1;
    localparam S_FETCH_LO = 3'd2;
    localparam S_EXECUTE  = 3'd3;
    localparam S_MEM      = 3'd4;
    localparam S_WRITEBACK= 3'd5;
    localparam S_HALTED   = 3'd6;
    localparam S_FETCH_GAP= 3'd7; // 1-cycle imem_valid turnaround between
                                    // the hi-byte and lo-byte fetches (see
                                    // note at S_FETCH_HI below)

    reg [2:0]  state;
    reg [15:0] pc;
    reg [7:0]  instr_hi;
    reg [15:0] instr;   // {instr_hi, instr_lo}

    wire [3:0] opcode = instr[15:12];
    wire [2:0] rd_f   = instr[11:9];
    wire [2:0] rs1_f  = instr[8:6];
    wire [2:0] rs2_f  = instr[5:3];       // R-type only
    wire [5:0] imm6   = instr[5:0];       // I-type only
    wire [7:0] imm_sext = {{2{imm6[5]}}, imm6};

	// *** Bug fix (see chat): SLL/SRL are I-type per docs/ISA.md (shift
	// amount = imm6[2:0]), not R-type. Having them here made the regfile
	// rs2_addr mux and the ALU's b-operand mux both source a register
	// (decoded from the immediate field's own upper 3 bits) instead of
	// the sign-extended immediate - confirmed empirically: both shifts
	// silently became no-ops because that bogus "register" happened to
	// decode to r0 (always zero) in a real test program. ***
	wire is_r_type = (opcode == OP_ADD) || (opcode == OP_SUB) ||
				(opcode == OP_AND) || (opcode == OP_OR) ||
				(opcode == OP_XOR);

    // BLT is I-type-encoded but, like BEQ, its second operand is a
    // *register* (addressed via the rd field, not an immediate) - see
    // regfile's rs2_addr mux below. The ALU's second operand must follow
    // the same rule, or BLT ends up comparing rs1 against the immediate
    // field instead of against rs2.
    wire alu_uses_reg_b = is_r_type || (opcode == OP_BLT);

    // Register file
    wire [7:0] rs1_data, rs2_data;
    reg  [2:0] rf_rd_addr;
    reg  [7:0] rf_rd_data;
    reg        rf_rd_we;

    a8_regfile regfile (
        .clk      (clk),
        .rst_n    (rst_n),
        .rs1_addr (rs1_f),
        .rs2_addr (is_r_type ? rs2_f : rd_f), // for SW/BEQ/BLT the 2nd
                                                // operand register is
                                                // encoded in the rd field
                                                // (see docs/ISA.md)
        .rs1_data (rs1_data),
        .rs2_data (rs2_data),
        .rd_addr  (rf_rd_addr),
        .rd_data  (rf_rd_data),
        .rd_we    (rf_rd_we)
    );

    // ALU
    wire [3:0] alu_op = opcode;
    wire [7:0] alu_b  = alu_uses_reg_b ? rs2_data : imm_sext;
    wire [7:0] alu_result;
    wire       alu_lt;

    a8_alu alu (
        .opcode      (alu_op),
        .a           (rs1_data),
        .b           (alu_b),
        .result      (alu_result),
        .lt_unsigned (alu_lt)
    );

    
    reg [15:0] next_pc;

    assign halted = (state == S_HALTED);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_RESET;
            pc         <= 16'h0000;
            imem_valid <= 1'b0;
            dmem_valid <= 1'b0;
            dmem_we    <= 1'b0;
            rf_rd_we   <= 1'b0;
        end else begin
            rf_rd_we   <= 1'b0; // default: no writeback this cycle
            dmem_valid <= 1'b0; // pulse, not level
            imem_valid <= 1'b0;

            case (state)
                S_RESET: begin
                    pc         <= 16'h0000;
                    state      <= S_FETCH_HI;
                end

                S_FETCH_HI: begin
                    imem_addr <= pc;
                    if (imem_ready) begin
                        // Drop imem_valid THIS cycle rather than leaving
                        // it asserted through the transition - otherwise,
                        // against a memory that generates ready as a
                        // registered (1-cycle-delayed) function of valid,
                        // the extra cycle of held valid produces a
                        // trailing/stale ready pulse that outlives a
                        // fixed-length bubble (see S_FETCH_GAP below).
                        imem_valid <= 1'b0;
                        instr_hi   <= imem_rdata;
                        state      <= S_FETCH_GAP;
                    end else begin
                        imem_valid <= 1'b1;
                    end
                end

                S_FETCH_GAP: begin
                    // imem_valid stays deasserted (default at top of
                    // block) until the memory's ready for the HI-byte
                    // transaction has actually dropped. Waiting on the
                    // live signal instead of a fixed one-cycle bubble
                    // makes this robust to any downstream memory latency
                    // (a real QSPI flash/PSRAM controller may take more
                    // than one cycle for ready to fall after valid does).
                    if (!imem_ready)
                        state <= S_FETCH_LO;
                end

                S_FETCH_LO: begin
                    imem_addr <= pc + 16'd1;
                    if (imem_ready) begin
                        imem_valid <= 1'b0;
                        instr      <= {instr_hi, imem_rdata};
                        state      <= S_EXECUTE;
                    end else begin
                        imem_valid <= 1'b1;
                    end
                end

                S_EXECUTE: begin
                    // Default next PC: straight-line +2 (two bytes/instr)
                    next_pc <= pc + 16'd2;

                    case (opcode)
                        OP_HALT: state <= S_HALTED;

                        OP_LW: begin
                            dmem_addr  <= rs1_data + imm_sext;
                            dmem_we    <= 1'b0;
                            dmem_valid <= 1'b1;
                            state      <= S_MEM;
                        end

                        OP_SW: begin
                            dmem_addr  <= rs1_data + imm_sext;
                            dmem_wdata <= rs2_data; // rd field = source reg for SW
                            dmem_we    <= 1'b1;
                            dmem_valid <= 1'b1;
                            state      <= S_MEM;
                        end

                        OP_BEQ: begin
                            if (rs1_data == rs2_data)
                                next_pc <= pc + {{9{imm6[5]}}, imm6, 1'b0};  // FIX: 9 copies (was 8) to fill 16 bits
                            state <= S_WRITEBACK; // no register write, just PC update
                        end

                        OP_BLT: begin
                            if (alu_lt)
                                next_pc <= pc + {{9{imm6[5]}}, imm6, 1'b0};  // FIX: 9 copies (was 8) to fill 16 bits
                            state <= S_WRITEBACK;
                        end

                        OP_JAL: begin
                            rf_rd_addr <= 3'd7; // link register is always r7
                            rf_rd_data <= pc + 16'd2;
                            rf_rd_we   <= 1'b1;
                            next_pc    <= pc + {{9{imm6[5]}}, imm6, 1'b0};  // FIX: 9 copies (was 8) to fill 16 bits
                            state      <= S_WRITEBACK;
                        end

                        OP_JALR: begin
                            rf_rd_addr <= rd_f;
                            rf_rd_data <= pc + 16'd2;
                            rf_rd_we   <= 1'b1;
                            next_pc    <= {8'h00, rs1_data + imm_sext}; // FIX: force 8-bit add, then zero-extend
                            state      <= S_WRITEBACK;
                        end

                        OP_NOP: state <= S_WRITEBACK;

                        default: begin
                            // ADD/ADDI/SUB/AND/OR/XOR/SLL/SRL
                            rf_rd_addr <= rd_f;
                            rf_rd_data <= alu_result;
                            rf_rd_we   <= 1'b1;
                            state      <= S_WRITEBACK;
                        end
                    endcase
                end

			S_MEM: begin
				if (dmem_ready) begin
					// Drop dmem_valid THIS cycle rather than holding it
					// through the transition, mirroring the fix applied
					// to S_FETCH_HI/S_FETCH_LO - avoids the same class of
					// stale-ready hazard on the data-memory side (dormant
					// today only because RAM/peripherals happen to give
					// enough natural gap before the next dmem transaction;
					// this keeps it closed regardless of what IMEM/DMEM
					// this core is ever paired with).
					dmem_valid <= 1'b0;

					if (!dmem_we) begin
						rf_rd_addr <= rd_f;
						rf_rd_data <= dmem_rdata;
						rf_rd_we <= 1'b1;
					end

					state <= S_WRITEBACK;
				end else begin
					dmem_valid <= 1'b1;
				end
			end
                S_WRITEBACK: begin
                    pc    <= next_pc;
                    state <= S_FETCH_HI;
                end

                S_HALTED: begin
                    state <= S_HALTED; // stay halted until reset
                end

                default: state <= S_RESET;
            endcase
        end
    end

endmodule

