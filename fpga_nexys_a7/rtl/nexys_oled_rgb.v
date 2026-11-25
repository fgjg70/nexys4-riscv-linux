`timescale 1ns/1ps

module nexys_oled_rgb #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer SPI_HALF_CYCLES = 4,
    parameter integer LOGIC_POWER_CYCLES = CLOCK_HZ / 50,
    parameter integer LOGIC_SETTLE_CYCLES = CLOCK_HZ / 1000,
    parameter integer PANEL_SETTLE_CYCLES = CLOCK_HZ / 10,
    parameter integer CLEAR_SETTLE_CYCLES = CLOCK_HZ / 200
) (
    input wire clk,
    input wire reset,
    input wire camera_ready,
    input wire show_bars,
    input wire pixel_write,
    input wire [14:0] pixel_address,
    input wire [15:0] pixel_data,
    input wire frame_done,
    output reg cs_n,
    output reg mosi,
    output reg sclk,
    output reg dc,
    output reg reset_n,
    output reg vccen,
    output reg pmoden
);
    localparam [3:0] LOGIC_ON=0, RESET_LOW=1, RESET_HIGH=2, INIT=3,
        CLEAR_WAIT=4, PANEL_ON=5, ENABLE_DISPLAY=6, DISPLAY_SETTLE=7, IDLE=8, DISPLAY=9;
    localparam [5:0] LAST_INIT_BYTE = 49;
    localparam integer SPI_TIMER_BITS = SPI_HALF_CYCLES < 2 ? 1 : $clog2(SPI_HALF_CYCLES);
    reg [3:0] state;
    reg [31:0] wait_cycles;
    reg [5:0] init_index;
    reg [SPI_TIMER_BITS-1:0] spi_timer;
    reg [15:0] spi_shift;
    reg [4:0] spi_bits;
    wire spi_idle = cs_n;

    // Sample a 160x120 frame at even rows and columns. Keep a complete 80x60
    // frame stable while sending it, with 8 columns and 2 rows of black border.
    (* ram_style = "block" *) reg [15:0] preview [0:4799];
    reg capturing, frame_available;
    reg [7:0] camera_x;
    reg [6:0] camera_y;
    reg [12:0] write_index;
    reg [6:0] screen_x;
    reg [5:0] screen_y;
    reg [12:0] row_base;
    reg displayed, displaying_preview;
    reg [15:0] preview_pixel;
    wire want_preview = camera_ready && !show_bars;
    wire start_preview = state == IDLE && spi_idle && want_preview && frame_available;
    wire start_capture = camera_ready && pixel_write && pixel_address == 0 &&
        !frame_available && state != DISPLAY;
    wire sample_pixel = camera_ready && pixel_write && pixel_address != 0 &&
        capturing && !camera_x[0] && !camera_y[0] && write_index < 4800;
    wire in_preview = screen_x >= 8 && screen_x < 88 && screen_y >= 2 && screen_y < 62;
    wire [12:0] read_index = in_preview ? row_base + screen_x - 13'd8 : 13'd0;
    wire [15:0] screen_pixel = displaying_preview ? (in_preview ? preview_pixel : 16'd0) : bars(screen_x);

    always @(posedge clk) begin
        if (!reset && (start_capture || sample_pixel))
            preview[start_capture ? 13'd0 : write_index] <= pixel_data;
        preview_pixel <= preview[read_index];

        if (reset || !camera_ready) begin
            capturing <= 0;
            frame_available <= 0;
            camera_x <= 0;
            camera_y <= 0;
            write_index <= 0;
        end else begin
            if (start_preview) frame_available <= 0;
            if (frame_done) begin
                if (capturing && write_index == 4800) frame_available <= 1;
                capturing <= 0;
            end
            if (pixel_write && pixel_address == 0) begin
                capturing <= start_capture;
                camera_x <= 1;
                camera_y <= 0;
                write_index <= 1;
            end else if (pixel_write && capturing) begin
                if (camera_x == 159) begin
                    camera_x <= 0;
                    camera_y <= camera_y + 1'b1;
                end else camera_x <= camera_x + 1'b1;
                if (sample_pixel) write_index <= write_index + 1'b1;
            end
        end
    end

    function [15:0] bars(input [6:0] x);
        begin
            if      (x < 12) bars = 16'hffff;
            else if (x < 24) bars = 16'hffe0;
            else if (x < 36) bars = 16'h07ff;
            else if (x < 48) bars = 16'h07e0;
            else if (x < 60) bars = 16'hf81f;
            else if (x < 72) bars = 16'hf800;
            else if (x < 84) bars = 16'h001f;
            else             bars = 16'h0000;
        end
    endfunction

    function [7:0] init_byte(input [5:0] index);
        begin
            case (index)
                0: init_byte = 8'hfd; // Unlock commands
                1: init_byte = 8'h12;
                2: init_byte = 8'hae; // Display off
                3: init_byte = 8'ha0;
                4: init_byte = 8'h72; // RGB565, horizontal increment, column remap
                5: init_byte = 8'ha1;
                6: init_byte = 8'h00;
                7: init_byte = 8'ha2;
                8: init_byte = 8'h00;
                9: init_byte = 8'ha4; // Normal display from GDDRAM
                10: init_byte = 8'ha8;
                11: init_byte = 8'h3f;
                12: init_byte = 8'had;
                13: init_byte = 8'h8e;
                14: init_byte = 8'hb0;
                15: init_byte = 8'h0b;
                16: init_byte = 8'hb1;
                17: init_byte = 8'h31;
                18: init_byte = 8'hb3;
                19: init_byte = 8'hf0;
                20: init_byte = 8'h8a;
                21: init_byte = 8'h64;
                22: init_byte = 8'h8b;
                23: init_byte = 8'h78;
                24: init_byte = 8'h8c;
                25: init_byte = 8'h64;
                26: init_byte = 8'hbb;
                27: init_byte = 8'h3a;
                28: init_byte = 8'hbe;
                29: init_byte = 8'h3e;
                30: init_byte = 8'h87;
                31: init_byte = 8'h06;
                32: init_byte = 8'h81;
                33: init_byte = 8'h91;
                34: init_byte = 8'h82;
                35: init_byte = 8'h50;
                36: init_byte = 8'h83;
                37: init_byte = 8'h7d;
                38: init_byte = 8'h2e; // Disable scrolling
                39: init_byte = 8'h15; // Set columns 0..95
                40: init_byte = 8'h00;
                41: init_byte = 8'h5f;
                42: init_byte = 8'h75; // Set rows 0..63
                43: init_byte = 8'h00;
                44: init_byte = 8'h3f;
                45: init_byte = 8'h25; // Clear the panel before enabling VCC
                46: init_byte = 8'h00;
                47: init_byte = 8'h00;
                48: init_byte = 8'h5f;
                49: init_byte = 8'h3f;
                default: init_byte = 0;
            endcase
        end
    endfunction

    wire command = state == INIT || state == ENABLE_DISPLAY;
    wire [7:0] command_byte = state == INIT ? init_byte(init_index) : 8'haf;
    wire [15:0] spi_word = command ? {command_byte, 8'd0} : screen_pixel;
    wire send_word = (state == INIT && init_index <= LAST_INIT_BYTE) ||
        (state == ENABLE_DISPLAY && init_index == 0) || state == DISPLAY;

    always @(posedge clk) begin
        if (reset) begin
            cs_n <= 1;
            mosi <= 0;
            sclk <= 1;
            dc <= 0;
            spi_shift <= 0;
            spi_bits <= 0;
            spi_timer <= 0;
        end else if (spi_idle) begin
            if (send_word) begin
                cs_n <= 0;
                dc <= !command;
                spi_shift <= spi_word;
                spi_bits <= command ? 5'd8 : 5'd16;
                spi_timer <= SPI_HALF_CYCLES - 1;
            end
        end else if (spi_timer != 0) spi_timer <= spi_timer - 1'b1;
        else begin
            spi_timer <= SPI_HALF_CYCLES - 1;
            // SPI mode 3. Change data on falling SCK, sample on rising SCK.
            if (!sclk) begin
                sclk <= 1;
                spi_bits <= spi_bits - 1'b1;
            end else if (spi_bits != 0) begin
                sclk <= 0;
                mosi <= spi_shift[15];
                spi_shift <= {spi_shift[14:0], 1'b0};
            end else cs_n <= 1;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            state <= LOGIC_ON;
            wait_cycles <= LOGIC_POWER_CYCLES;
            init_index <= 0;
            reset_n <= 1;
            vccen <= 0;
            pmoden <= 0;
            screen_x <= 0;
            screen_y <= 0;
            row_base <= 0;
            displayed <= 0;
            displaying_preview <= 0;
        end else begin
            case (state)
                LOGIC_ON, RESET_LOW, RESET_HIGH, CLEAR_WAIT, PANEL_ON, DISPLAY_SETTLE: begin
                    if (wait_cycles != 0) wait_cycles <= wait_cycles - 1'b1;
                    else begin
                        wait_cycles <= LOGIC_SETTLE_CYCLES;
                        case (state)
                            LOGIC_ON: begin reset_n <= 0; state <= RESET_LOW; end
                            RESET_LOW: begin reset_n <= 1; state <= RESET_HIGH; end
                            RESET_HIGH: state <= INIT;
                            CLEAR_WAIT: begin
                                vccen <= 1;
                                wait_cycles <= PANEL_SETTLE_CYCLES;
                                state <= PANEL_ON;
                            end
                            PANEL_ON: begin init_index <= 0; state <= ENABLE_DISPLAY; end
                            default: state <= IDLE;
                        endcase
                    end
                    pmoden <= 1;
                end
                INIT: if (spi_idle) begin
                    if (init_index <= LAST_INIT_BYTE) init_index <= init_index + 1'b1;
                    else begin
                        wait_cycles <= CLEAR_SETTLE_CYCLES;
                        state <= CLEAR_WAIT;
                    end
                end
                ENABLE_DISPLAY: if (spi_idle) begin
                    if (init_index == 0) init_index <= 1;
                    else begin
                        wait_cycles <= PANEL_SETTLE_CYCLES;
                        state <= DISPLAY_SETTLE;
                    end
                end
                IDLE: if (spi_idle && (start_preview || !displayed || (displaying_preview && !want_preview))) begin
                    screen_x <= 0;
                    screen_y <= 0;
                    row_base <= 0;
                    displayed <= 1;
                    displaying_preview <= start_preview;
                    state <= DISPLAY;
                end
                DISPLAY: if (spi_idle) begin
                    if (screen_x == 95) begin
                        screen_x <= 0;
                        screen_y <= screen_y + 1'b1;
                        if (screen_y >= 2 && screen_y < 61) row_base <= row_base + 13'd80;
                        if (screen_y == 63) state <= IDLE;
                    end else screen_x <= screen_x + 1'b1;
                end
                default: state <= LOGIC_ON;
            endcase
        end
    end
endmodule
