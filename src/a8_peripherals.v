`default_nettype none

module a8_peripherals (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [7:0] addr,
    input  wire [7:0] wdata,
    input  wire       we,
    input  wire       valid,

    output reg  [7:0] rdata,
    output reg        ready,
    output wire       hit,

    // GPIO
    input  wire [7:0] gpio_in,
    output reg  [7:0] gpio_out,
    output reg  [7:0] gpio_dir,

    // PWM
    output wire       pwm_out
);

    //------------------------------------------------------------------
    // Address Map
    //
    // F0 GPIO_OUT
    // F1 GPIO_IN
    // F2 GPIO_DIR
    //
    // F8 TIMER_LO
    // F9 TIMER_HI
    // FA TIMER_CTRL
    //    bit0 = enable
    //    bit1 = reset counter
    //
    // FB TIMER_FLAG
    //    bit0 = overflow
    //
    // FC PWM_DUTY
    // FD PWM_CTRL
    //    bit0 = enable
    //------------------------------------------------------------------

    assign hit =
           (addr == 8'hF0)
        || (addr == 8'hF1)
        || (addr == 8'hF2)
        || (addr == 8'hF8)
        || (addr == 8'hF9)
        || (addr == 8'hFA)
        || (addr == 8'hFB)
        || (addr == 8'hFC)
        || (addr == 8'hFD);

    //------------------------------------------------------------------
    // Timer
    //------------------------------------------------------------------

    reg [15:0] timer_cnt;
    reg        timer_enable;
    reg        timer_overflow;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timer_cnt      <= 16'h0000;
            timer_enable   <= 1'b0;
            timer_overflow <= 1'b0;
        end
        else begin

            // Control register
            if (valid && we && addr == 8'hFA) begin
                timer_enable <= wdata[0];

                if (wdata[1])
                    timer_cnt <= 16'h0000;
            end

            // Timer run
            else if (timer_enable) begin
                timer_cnt <= timer_cnt + 16'd1;

                if (timer_cnt == 16'hFFFF)
                    timer_overflow <= 1'b1;
            end

            // Clear overflow flag
            if (valid && we && addr == 8'hFB)
                timer_overflow <= 1'b0;
        end
    end

    //------------------------------------------------------------------
    // PWM
    //------------------------------------------------------------------

    reg [7:0] pwm_counter;
    reg [7:0] pwm_duty;
    reg       pwm_enable;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pwm_counter <= 8'h00;
            pwm_duty    <= 8'h00;
            pwm_enable  <= 1'b0;
        end
        else begin
            pwm_counter <= pwm_counter + 8'd1;

            if (valid && we && addr == 8'hFC)
                pwm_duty <= wdata;

            if (valid && we && addr == 8'hFD)
                pwm_enable <= wdata[0];
        end
    end

    assign pwm_out =
        pwm_enable &&
        (
            (pwm_duty == 8'hFF) ||
            (pwm_counter < pwm_duty)
        );

    //------------------------------------------------------------------
    // Bus Interface
    //------------------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ready    <= 1'b0;
            rdata    <= 8'h00;

            gpio_out <= 8'h00;
            gpio_dir <= 8'h00;
        end
        else begin

            ready <= 1'b0;

            if (valid && hit) begin

                ready <= 1'b1;

                case (addr)

                    //--------------------------------------------------
                    // GPIO
                    //--------------------------------------------------

                    8'hF0: begin
                        if (we)
                            gpio_out <= wdata;

                        rdata <= gpio_out;
                    end

                    8'hF1: begin
                        rdata <= gpio_in;
                    end

                    8'hF2: begin
                        if (we)
                            gpio_dir <= wdata;

                        rdata <= gpio_dir;
                    end

                    //--------------------------------------------------
                    // TIMER
                    //--------------------------------------------------

                    8'hF8:
                        rdata <= timer_cnt[7:0];

                    8'hF9:
                        rdata <= timer_cnt[15:8];

                    8'hFA:
                        rdata <= {
                            6'b000000,
                            1'b0,
                            timer_enable
                        };

                    8'hFB:
                        rdata <= {
                            7'b0000000,
                            timer_overflow
                        };

                    //--------------------------------------------------
                    // PWM
                    //--------------------------------------------------

                    8'hFC:
                        rdata <= pwm_duty;

                    8'hFD:
                        rdata <= {
                            7'b0000000,
                            pwm_enable
                        };

                    default:
                        rdata <= 8'h00;

                endcase
            end
        end
    end

endmodule