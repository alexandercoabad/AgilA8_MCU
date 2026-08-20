`default_nettype none

module tt_um_agila8 (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    wire _unused_ena = ena;

    //------------------------------------------------------------------
    // CPU <-> Memory Interface
    //------------------------------------------------------------------

    wire [15:0] imem_addr;
    wire        imem_valid;
    wire [7:0]  imem_rdata;
    wire        imem_ready;

    wire [7:0]  dmem_addr;
    wire [7:0]  dmem_wdata;
    wire        dmem_we;
    wire        dmem_valid;
    wire [7:0]  dmem_rdata;
    wire        dmem_ready;

    wire halted;

    a8_core core (
        .clk        (clk),
        .rst_n      (rst_n),

        .imem_addr  (imem_addr),
        .imem_valid (imem_valid),
        .imem_rdata (imem_rdata),
        .imem_ready (imem_ready),

        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_we    (dmem_we),
        .dmem_valid (dmem_valid),
        .dmem_rdata (dmem_rdata),
        .dmem_ready (dmem_ready),

        .halted     (halted)
    );

    //------------------------------------------------------------------
    // Peripheral / SPI / RAM address decode
    //
    // NOTE - address map change from the pre-SPI-controller README: that
    // doc listed 0xF3-0xF7 as part of the general PSRAM window. SPI_DATA
    // (0xF3) and SPI_CTRL (0xF4) now claim two of those five bytes for
    // the new peripheral - any existing software that stored ordinary
    // data at DMEM[0xF3] or DMEM[0xF4] will now silently hit the SPI
    // controller instead. 0xF5-0xF7 remain plain PSRAM, unaffected.
    //
    // NOTE - RAM32 split: 0x00-0x7F now goes to on-chip ram32 instead of
    // external PSRAM, making the QSPI Pmod optional for DMEM as long as
    // software stays inside that range - see ram32.v's header for the
    // uninitialized-on-reset caveat this introduces, and README/
    // docs/info.md for the AREA CAVEAT this creates (ram32 is a plain
    // 128-byte flip-flop array, not a dense macro - this was
    // deliberately NOT done earlier in the project specifically because
    // it doesn't fit a 1x2 tile budget; see chat/commit history for the
    // full reasoning). 0x80-0xEF remains external PSRAM - flash (CS0)
    // is still required for IMEM regardless, this only makes the Pmod
    // optional for the DMEM side, not for the design as a whole.
    //------------------------------------------------------------------

    wire ram32_hit_comb = (dmem_addr < 8'h80);

    wire periph_hit_comb =
           (dmem_addr == 8'hF0)
        || (dmem_addr == 8'hF1)
        || (dmem_addr == 8'hF2)
        || (dmem_addr == 8'hF8)
        || (dmem_addr == 8'hF9)
        || (dmem_addr == 8'hFA)
        || (dmem_addr == 8'hFB)
        || (dmem_addr == 8'hFC)
        || (dmem_addr == 8'hFD);

    wire spi_hit_comb =
           (dmem_addr == 8'hF3)
        || (dmem_addr == 8'hF4);

    wire iram_w_hit_comb =
           (dmem_addr == 8'hF5)
        || (dmem_addr == 8'hF6);

    //------------------------------------------------------------------
    // On-chip IMEM (0x0000-0x00FF) - boot_rom (0x00-0x7F, fixed
    // content) + iram (0x80-0xFF, written at runtime via IMEM_WADDR/
    // IMEM_WDATA below). This is what makes the QSPI Pmod fully
    // optional: address 0x0000, the reset vector, now always resolves
    // to on-chip content whether or not flash is even connected. See
    // boot_rom.v's header and build_boot_rom.py's docstring for the
    // bootloader protocol that lives here.
    //
    // FLASH_MODE (0xF7, write-any-value-to-set, sticky until reset):
    // boot_rom's timeout fallback needs to hand control to flash, but
    // a8_core's JALR truncates its target to 8 bits ({8'h00, rs1_data
    // + imm_sext} in a8_core.v) - it can only ever reach 0x0000-0x00FF,
    // and JAL's PC-relative range (+-62 bytes) can't cover the gap to
    // flash space either. So instead of trying to jump TO flash (which
    // no instruction in this ISA can do from boot_rom's fixed location),
    // this flag changes what memory backs address 0x0000 itself: once
    // set, imem_addr 0x0000 and up resolve directly to flash (unrebased
    // - flash's own byte 0 is whatever a normal, existing flash image
    // already has at its start, unchanged), and boot_rom/iram become
    // completely unreachable until the next reset. The bootloader's
    // timeout path just needs SW FLASH_MODE then JALR to 0x0000 - both
    // trivially within JALR's 8-bit reach.
    //------------------------------------------------------------------

    reg  flash_mode_r;
    wire flash_mode_hit_comb = (dmem_addr == 8'hF7);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            flash_mode_r <= 1'b0;
        else if (dmem_valid && dmem_we && flash_mode_hit_comb)
            flash_mode_r <= 1'b1;
    end

    wire        onchip_imem_hit = (imem_addr < 16'h0100) && !flash_mode_r;
    wire        boot_rom_hit    = (imem_addr < 16'h0080) && !flash_mode_r;

    wire [7:0]  boot_rom_rdata;
    wire        boot_rom_ready;

    boot_rom boot_rom_inst (
        .clk   (clk),
        .rst_n (rst_n),

        .addr  (imem_addr[6:0]),
        .valid (imem_valid && onchip_imem_hit && boot_rom_hit),

        .rdata (boot_rom_rdata),
        .ready (boot_rom_ready)
    );

    wire [7:0]  iram_rdata;
    wire        iram_ready;
    wire [7:0]  iram_dmem_rdata;
    wire        iram_dmem_ready;
    wire        iram_dmem_hit;

    iram iram_inst (
        .clk   (clk),
        .rst_n (rst_n),

        .imem_addr  (imem_addr[6:0]),
        .imem_valid (imem_valid && onchip_imem_hit && !boot_rom_hit),
        .imem_rdata (iram_rdata),
        .imem_ready (iram_ready),

        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_we    (dmem_we),
        .dmem_valid (dmem_valid && iram_w_hit_comb),
        .dmem_rdata (iram_dmem_rdata),
        .dmem_ready (iram_dmem_ready),
        .dmem_hit   (iram_dmem_hit)
    );

    wire [7:0] ram32_rdata;
    wire       ram32_ready;

    ram32 ram32_inst (
        .clk   (clk),
        .rst_n (rst_n),

        .addr  (dmem_addr),
        .wdata (dmem_wdata),
        .we    (dmem_we),
        .valid (dmem_valid && ram32_hit_comb),

        .rdata (ram32_rdata),
        .ready (ram32_ready)
    );

    //------------------------------------------------------------------
    // Shared QSPI engine - one physical SCK/MOSI/MISO shift engine
    // driving three front-ends (flash/CS0, PSRAM/CS1, generic SPI/CS2).
    // Replaces separate qspi_flash_reader.v + qspi_psram_ctrl.v +
    // spi_ctrl.v instances - see qspi_shared_engine.v header for why
    // this is safe to share (relies on a8_core never asserting
    // imem_valid and dmem_valid in the same cycle, and dmem-side
    // requests being mutually exclusive by address decode above).
    //------------------------------------------------------------------

    wire cs_n_flash, cs_n_psram, cs_n_spi, spi_sck_shared, spi_mosi_shared;
    wire spi_miso_shared = uio_in[2];

    wire [7:0] ram_rdata_r;
    wire       ram_ready_r;
    wire [7:0] spi_rdata;
    wire       spi_ready;
    wire       spi_hit_engine;
    wire [7:0] flash_rdata_w;
    wire       flash_ready_w;

    qspi_shared_engine #(
        .HALF_PERIOD_CYCLES(1),
        .DEFAULT_READ_DELAY(2)
    ) qspi (
        .clk   (clk),
        .rst_n (rst_n),

        .flash_addr           (imem_addr - 16'h0100),
        .flash_valid          (imem_valid && !onchip_imem_hit),
        .flash_rdata          (flash_rdata_w),
        .flash_ready          (flash_ready_w),
        .flash_read_delay_cfg (4'd2),

        .psram_addr           (dmem_addr),
        .psram_wdata          (dmem_wdata),
        .psram_we             (dmem_we),
        .psram_valid          (dmem_valid && !ram32_hit_comb && !periph_hit_comb && !spi_hit_comb && !iram_w_hit_comb),
        .psram_rdata          (ram_rdata_r),
        .psram_ready          (ram_ready_r),
        .psram_read_delay_cfg (4'd2),

        .spi_addr  (dmem_addr),
        .spi_wdata (dmem_wdata),
        .spi_we    (dmem_we),
        .spi_valid (dmem_valid && spi_hit_comb),
        .spi_rdata (spi_rdata),
        .spi_ready (spi_ready),
        .spi_hit   (spi_hit_engine),

        .cs_n_flash (cs_n_flash),
        .cs_n_psram (cs_n_psram),
        .cs_n_spi   (cs_n_spi),
        .sck        (spi_sck_shared),
        .mosi       (spi_mosi_shared),
        .miso       (spi_miso_shared)
    );

    //------------------------------------------------------------------
    // IMEM Mux (boot_rom / iram / flash - see the on-chip IMEM block
    // above for address ranges)
    //------------------------------------------------------------------

    assign imem_rdata =
        boot_rom_hit    ? boot_rom_rdata :
        onchip_imem_hit ? iram_rdata     :
                           flash_rdata_w;

    assign imem_ready =
        boot_rom_hit    ? boot_rom_ready :
        onchip_imem_hit ? iram_ready     :
                           flash_ready_w;

    //------------------------------------------------------------------
    // Peripheral Block (GPIO / Timer / PWM - unaffected by the SPI merge)
    //------------------------------------------------------------------

    wire [7:0] periph_rdata;
    wire       periph_ready;
    wire       periph_hit;

    wire [7:0] gpio_out_w;
    wire [7:0] gpio_dir_w;

    wire       pwm_out_w;

    a8_peripherals periph (
        .clk      (clk),
        .rst_n    (rst_n),

        .addr     (dmem_addr),
        .wdata    (dmem_wdata),
        .we       (dmem_we),
        .valid    (dmem_valid && periph_hit_comb),

        .rdata    (periph_rdata),
        .ready    (periph_ready),
        .hit      (periph_hit),

        .gpio_in  (ui_in),
        .gpio_out (gpio_out_w),
        .gpio_dir (gpio_dir_w),

        .pwm_out  (pwm_out_w)
    );

    //------------------------------------------------------------------
    // DMEM Mux
    //------------------------------------------------------------------

    assign dmem_ready =
        ram32_hit_comb   ? ram32_ready     :
        periph_hit_comb  ? periph_ready    :
        spi_hit_comb     ? spi_ready       :
        iram_w_hit_comb  ? iram_dmem_ready :
                            ram_ready_r;

    assign dmem_rdata =
        ram32_hit_comb   ? ram32_rdata     :
        periph_hit_comb  ? periph_rdata    :
        spi_hit_comb     ? spi_rdata       :
        iram_w_hit_comb  ? iram_dmem_rdata :
                            ram_rdata_r;

    //------------------------------------------------------------------
    // Outputs
    //------------------------------------------------------------------

    assign uo_out[6:0] = gpio_out_w[6:0];
    assign uo_out[7]   = pwm_out_w;

    //------------------------------------------------------------------
    // QSPI PMOD
    //
    // uio[7:0] = {CS2, CS1, SD3, SD2, SCK, SD1, SD0, CS0}
    //------------------------------------------------------------------

    assign uio_out = {
        cs_n_spi,          // CS2 (general-purpose SPI controller)
        cs_n_psram,        // CS1 (RAM A - DMEM)
        1'b1,              // SD3
        1'b1,              // SD2
        spi_sck_shared,    // SCK
        1'b0,              // SD1 (input)
        spi_mosi_shared,   // SD0
        cs_n_flash         // CS0
    };

    assign uio_oe = 8'b1111_1011;

    //------------------------------------------------------------------
    // Unused warning suppression
    //------------------------------------------------------------------

    wire _unused_periph =
        &{1'b0, periph_hit, gpio_dir_w, spi_hit_engine, iram_dmem_hit};

endmodule
