`timescale 1ns/1ps

module video_check #(
    parameter integer VGA_MODE = 0
) (output reg finished = 0);
    reg clk = 0;
    always #20 clk = !clk;
    reg reset = 1;
    wire frame_tick, hsync, vsync, de;
    integer cycles, enabled_pixels, active_pixels, line_count, hsync_pixels, vsync_lines;
    vision_lcd #(.VGA_MODE(VGA_MODE)) video (
        .clk(clk), .reset(reset), .show_bars(1'b1), .frame_valid(1'b0), .configured(1'b0), .failed(1'b0),
        .overlay_valid(1'b0), .extra_boxes(117'd0), .box_left(10'd0), .box_top(9'd0),
        .box_right(10'd0), .box_bottom(9'd0), .label(6'd0), .panel_status(32'd0),
        .pass_count(32'd0), .reject_count(32'd0), .camera_diagnostics(128'd0),
        .image_pixel(16'd0), .image_address(), .frame_tick(frame_tick), .dclk(),
        .hsync(hsync), .vsync(vsync), .de(de), .red(), .green(), .blue()
    );
    initial begin
        cycles = 0;
        enabled_pixels = 0;
        active_pixels = 0;
        line_count = 0;
        hsync_pixels = 0;
        vsync_lines = 0;
        repeat (4) @(negedge clk);
        reset = 0;
        while (!frame_tick) @(negedge clk);
        @(posedge clk);
        forever begin
            if (video.pixel_enable) begin
                if (video.horizontal == 0) begin
                    line_count = line_count + 1;
                    if (video.vertical < (VGA_MODE ? 2 : 10)) vsync_lines = vsync_lines + 1;
                end
                if (video.horizontal < (VGA_MODE ? 96 : 41)) hsync_pixels = hsync_pixels + 1;
                enabled_pixels = enabled_pixels + 1;
                #1;
                if (de) active_pixels = active_pixels + 1;
            end
            @(negedge clk);
            cycles = cycles + 1;
            if (frame_tick) begin
                if (line_count != (VGA_MODE ? 525 : 286)) begin $display("FAIL Video line count failed mode=%0d count=%0d", VGA_MODE, line_count); $finish; end
                if (enabled_pixels != (VGA_MODE ? 800 * 525 : 525 * 286)) begin $display("FAIL Video frame size failed"); $finish; end
                if (active_pixels != 480 * 272) begin $display("FAIL Video viewport failed actual=%0d", active_pixels); $finish; end
                if (hsync_pixels != (VGA_MODE ? 96 * 525 : 41 * 286)) begin $display("FAIL Horizontal sync failed"); $finish; end
                if (vsync_lines != (VGA_MODE ? 2 : 10)) begin $display("FAIL Vertical sync failed"); $finish; end
                $display("PASS video mode=%0d pixels=%0d viewport=%0d lines=%0d", VGA_MODE, enabled_pixels, active_pixels, line_count);
                finished = 1;
                wait (reset);
            end
            @(posedge clk);
        end
    end
endmodule

module tb_video;
    wire vga_finished, lcd_finished;
    video_check #(.VGA_MODE(1)) vga (.finished(vga_finished));
    video_check #(.VGA_MODE(0)) lcd (.finished(lcd_finished));
    initial begin
        wait (vga_finished && lcd_finished);
        $display("PASS VGA timing and original LCD timing");
        $finish;
    end
    initial begin
        #30000000;
        begin $display("FAIL Video simulation watchdog expired"); $finish; end
    end
endmodule
