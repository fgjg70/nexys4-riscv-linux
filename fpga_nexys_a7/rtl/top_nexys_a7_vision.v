`timescale 1ns/1ps

module top_nexys_a7_vision #(
    parameter integer BIST_TEST_WORDS = 1024,
    parameter integer MODEL_MASK = 3
) (
    input wire clk100,
    input wire reset_n,
    input wire [3:0] buttons,
    input wire uart_rxd,
    output wire uart_txd,
    output wire [6:0] servo_pwm,
    output wire [15:0] led,
    output wire [3:0] vga_r,
    output wire [3:0] vga_g,
    output wire [3:0] vga_b,
    output wire vga_hsync,
    output wire vga_vsync,
    output wire cam_scl,
    inout wire cam_sda,
    input wire cam_vsync,
    input wire cam_href,
    input wire cam_pclk,
    input wire [7:0] cam_data,
    output wire cam_xclk,
    output wire cam_reset_n,
    output wire cam_pwdn,
    output wire oled_cs_n,
    output wire oled_mosi,
    output wire oled_sclk,
    output wire oled_dc,
    output wire oled_reset_n,
    output wire oled_vccen,
    output wire oled_pmoden,
    output wire [12:0] ddr2_addr,
    output wire [2:0] ddr2_ba,
    output wire ddr2_ras_n,
    output wire ddr2_cas_n,
    output wire ddr2_we_n,
    output wire [0:0] ddr2_ck_p,
    output wire [0:0] ddr2_ck_n,
    output wire [0:0] ddr2_cke,
    output wire [0:0] ddr2_cs_n,
    output wire [1:0] ddr2_dm,
    output wire [0:0] ddr2_odt,
    inout wire [15:0] ddr2_dq,
    inout wire [1:0] ddr2_dqs_p,
    inout wire [1:0] ddr2_dqs_n
);
    wire clk50, clk60, clk25, clk200, locked;
    wire reset_request = !reset_n || !locked;
    (* ASYNC_REG = "TRUE" *) reg [2:0] system_reset_sync;
    (* ASYNC_REG = "TRUE" *) reg [2:0] cpu_reset_sync;
    (* ASYNC_REG = "TRUE" *) reg [2:0] video_reset_sync;
    reg [15:0] powerup;
    wire reset = system_reset_sync[2] || !(&powerup);
    wire secondary_reset_request = reset_request || reset;
    wire cpu_reset = cpu_reset_sync[2];
    wire video_reset = video_reset_sync[2];
    reg [24:0] heartbeat;
    reg camera_clock_phase;
    reg [15:0] camera_reset_timer;
    reg oled_startup = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg [1:0] camera_sda_sync;
    wire configured, failed, frozen, show_bars, restart;
    wire [7:0] camera_pid, camera_version, camera_step;
    wire [3:0] capture_state;
    wire [15:0] camera_vsync_count, camera_timeout_count;
    wire [15:0] camera_pclk_count, camera_line_count, camera_bad_frame_count;
    wire [1:0] camera_levels;
    wire [127:0] camera_diagnostics;
    wire pixel_write, frame_done, frame_ack, frame_valid, display_valid;
    wire frame_tick, video_frame_tick;
    wire [15:0] frame_count, write_data, read_data;
    wire [14:0] write_address, read_address;
    wire overlay_valid, inference_busy, cpu_illegal;
    wire [116:0] extra_boxes;
    wire [9:0] box_left, box_right;
    wire [8:0] box_top, box_bottom;
    wire [5:0] label;
    wire [31:0] panel_status, pass_count, reject_count, benchmark_result;
    wire video_bars, video_configured, video_failed, video_overlay;
    wire [116:0] video_extra_boxes;
    wire [9:0] video_left, video_right;
    wire [8:0] video_top, video_bottom;
    wire [5:0] video_label;
    wire [31:0] video_status, video_pass, video_reject;
    wire [127:0] video_camera_diagnostics;
    wire [4:0] red, blue;
    wire [5:0] green;
    wire memory_read, memory_write, memory_ready;
    wire [31:0] memory_address, memory_wdata, memory_rdata, memory_status;
    wire [31:0] memory_error_address, memory_error_expected, memory_error_actual;
    wire [3:0] memory_wstrb;
    reg [27:0] memory_wait;
    reg memory_timeout;

    nexys_clocks clocks (
        .clk100(clk100), .reset(!reset_n), .clk50(clk50), .clk60(clk60),
        .clk25(clk25), .clk200(clk200), .locked(locked)
    );
    always @(posedge clk50 or posedge reset_request) begin
        if (reset_request) begin system_reset_sync <= 3'b111; powerup <= 0; end
        else begin
            system_reset_sync <= {system_reset_sync[1:0], 1'b0};
            if (system_reset_sync[2]) powerup <= 0;
            else if (!(&powerup)) powerup <= powerup + 1'b1;
        end
    end
    always @(posedge clk60 or posedge secondary_reset_request) begin
        if (secondary_reset_request) cpu_reset_sync <= 3'b111;
        else cpu_reset_sync <= {cpu_reset_sync[1:0], 1'b0};
    end
    always @(posedge clk25 or posedge secondary_reset_request) begin
        if (secondary_reset_request) video_reset_sync <= 3'b111;
        else video_reset_sync <= {video_reset_sync[1:0], 1'b0};
    end
    always @(posedge clk50) begin
        if (reset) begin
            heartbeat <= 0;
            camera_clock_phase <= 0;
            camera_reset_timer <= 0;
            camera_sda_sync <= 2'b11;
            memory_wait <= 0;
            memory_timeout <= 0;
        end else begin
            heartbeat <= heartbeat + 1'b1;
            camera_clock_phase <= !camera_clock_phase;
            camera_sda_sync <= {camera_sda_sync[0], cam_sda};
            if (restart) camera_reset_timer <= 0;
            else if (camera_reset_timer != 16'd50000) camera_reset_timer <= camera_reset_timer + 1'b1;
            if (!memory_status[1] && !memory_timeout) begin
                if (memory_wait == 250000000 - 1) memory_timeout <= 1;
                else memory_wait <= memory_wait + 1'b1;
            end
        end
    end
    assign cam_xclk = camera_clock_phase;
    assign cam_reset_n = !reset && camera_reset_timer == 16'd50000;
    assign cam_pwdn = 1'b0;
    // Keep the panel powered across a CPU reset.
    always @(posedge clk50) begin
        if (!reset) oled_startup <= 0;
    end
    assign vga_r = red[4:1];
    assign vga_g = green[5:2];
    assign vga_b = blue[4:1];
    assign led = {4'd0, frame_valid, benchmark_result != 0, cpu_illegal, failed, configured, inference_busy,
        memory_status[5], memory_status[3], memory_timeout || memory_status[6] || memory_status[4],
        memory_status[2], memory_status[1], heartbeat[24]};
    assign camera_diagnostics = {camera_pclk_count, camera_line_count, camera_bad_frame_count,
        camera_pid, camera_version, camera_step, camera_levels, cam_scl, camera_sda_sync[1],
        capture_state, camera_vsync_count, camera_timeout_count, frame_count};

    nexys_ddr2 #(.BIST_TEST_WORDS(BIST_TEST_WORDS)) ddr2 (
        .ref_clk200(clk200), .clk(clk50), .reset(reset),
        .memory_read(memory_read), .memory_write(memory_write), .memory_address(memory_address),
        .memory_wdata(memory_wdata), .memory_wstrb(memory_wstrb), .memory_ready(memory_ready),
        .memory_rdata(memory_rdata), .memory_status(memory_status),
        .error_address(memory_error_address), .error_expected(memory_error_expected), .error_actual(memory_error_actual),
        .ddr2_addr(ddr2_addr), .ddr2_ba(ddr2_ba), .ddr2_ras_n(ddr2_ras_n), .ddr2_cas_n(ddr2_cas_n),
        .ddr2_we_n(ddr2_we_n), .ddr2_ck_p(ddr2_ck_p), .ddr2_ck_n(ddr2_ck_n), .ddr2_cke(ddr2_cke),
        .ddr2_cs_n(ddr2_cs_n), .ddr2_dm(ddr2_dm), .ddr2_odt(ddr2_odt),
        .ddr2_dq(ddr2_dq), .ddr2_dqs_p(ddr2_dqs_p), .ddr2_dqs_n(ddr2_dqs_n)
    );
    nexys_ov5640 sensor_configuration (
        .clk(clk50), .reset(reset || !cam_reset_n), .restart(restart),
        .configured(configured), .failed(failed), .pid(camera_pid), .version(camera_version),
        .step(camera_step), .scl(cam_scl), .sda(cam_sda)
    );
    camera_dvp_capture #(.TIMEOUT_CYCLES(50000000)) capture (
        .clk(clk50), .reset(reset || restart || !cam_reset_n), .configured(configured), .freeze(frozen),
        .frame_ack(frame_ack), .vsync(cam_vsync), .href(cam_href), .pclk(cam_pclk), .data(cam_data),
        .pixel_write(pixel_write), .pixel_address(write_address), .pixel_data(write_data),
        .frame_done(frame_done), .frame_count(frame_count), .timeout_count(camera_timeout_count),
        .vsync_count(camera_vsync_count), .state(capture_state), .sync_levels(camera_levels),
        .pclk_count(camera_pclk_count), .line_count(camera_line_count), .bad_frame_count(camera_bad_frame_count)
    );
    nexys_oled_rgb oled (
        .clk(clk50), .reset(oled_startup), .camera_ready(configured && !reset && !restart), .show_bars(show_bars),
        .pixel_write(pixel_write), .pixel_address(write_address), .pixel_data(write_data), .frame_done(frame_done),
        .cs_n(oled_cs_n), .mosi(oled_mosi), .sclk(oled_sclk), .dc(oled_dc),
        .reset_n(oled_reset_n), .vccen(oled_vccen), .pmoden(oled_pmoden)
    );
    vision_framebuffer framebuffer (
        .write_clk(clk50), .read_clk(clk25), .reset(reset || restart || !configured),
        .pixel_write(pixel_write), .write_address(write_address), .write_data(write_data),
        .frame_done(frame_done), .frame_tick(video_frame_tick), .read_address(read_address),
        .read_data(read_data), .frame_valid(frame_valid), .frame_ack(frame_ack), .display_valid(display_valid)
    );
    vision_soc #(.MEMORY_ENABLE(1), .MEMORY_BYTES(32'h08000000), .YOLO_MODEL_WORDS(0), .MODEL_MASK(MODEL_MASK)) system (
        .clk(clk50), .reset(reset), .cpu_clk(clk60), .cpu_reset(cpu_reset),
        .keys_n(~buttons), .uart_rxd(uart_rxd), .uart_txd(uart_txd), .servo_pwm(servo_pwm),
        .memory_read(memory_read), .memory_write(memory_write), .memory_address(memory_address),
        .memory_wdata(memory_wdata), .memory_wstrb(memory_wstrb), .memory_ready(memory_ready),
        .memory_rdata(memory_rdata), .memory_status(memory_status), .memory_error_address(memory_error_address),
        .memory_error_expected(memory_error_expected), .memory_error_actual(memory_error_actual),
        .configured(configured), .failed(failed), .frame_valid(frame_valid), .frame_count(frame_count),
        .frame_tick(frame_tick), .pixel_write(pixel_write), .pixel_address(write_address), .pixel_data(write_data),
        .frame_done(frame_done), .frozen(frozen), .show_bars(show_bars), .restart(restart),
        .overlay_valid(overlay_valid), .extra_boxes(extra_boxes), .box_left(box_left), .box_top(box_top),
        .box_right(box_right), .box_bottom(box_bottom), .label(label), .panel_status(panel_status),
        .pass_count(pass_count), .reject_count(reject_count), .inference_busy(inference_busy),
        .benchmark_result(benchmark_result), .cpu_illegal(cpu_illegal)
    );
    vision_video_bridge #(.PAYLOAD_BITS(389)) video_bridge (
        .system_clk(clk50), .system_reset(reset),
        .source_payload({extra_boxes, camera_diagnostics, show_bars, configured, failed, overlay_valid,
            box_left, box_top, box_right, box_bottom, label, panel_status, pass_count, reject_count}),
        .video_clk(clk25), .video_reset(video_reset), .video_frame_tick(video_frame_tick),
        .display_payload({video_extra_boxes, video_camera_diagnostics, video_bars, video_configured,
            video_failed, video_overlay, video_left, video_top, video_right, video_bottom,
            video_label, video_status, video_pass, video_reject}), .system_frame_tick(frame_tick)
    );
    vision_lcd #(.VGA_MODE(1)) video (
        .clk(clk25), .reset(video_reset), .show_bars(video_bars), .frame_valid(display_valid),
        .configured(video_configured), .failed(video_failed), .overlay_valid(video_overlay),
        .extra_boxes(video_extra_boxes), .box_left(video_left), .box_top(video_top),
        .box_right(video_right), .box_bottom(video_bottom), .label(video_label),
        .panel_status(video_status), .pass_count(video_pass), .reject_count(video_reject),
        .camera_diagnostics(video_camera_diagnostics), .image_pixel(read_data), .image_address(read_address),
        .frame_tick(video_frame_tick), .dclk(), .hsync(vga_hsync), .vsync(vga_vsync), .de(),
        .red(red), .green(green), .blue(blue)
    );
endmodule
