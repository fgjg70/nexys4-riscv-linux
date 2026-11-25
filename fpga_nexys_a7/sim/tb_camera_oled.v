`timescale 1ns/1ps

module tb_camera_oled;
    reg clk = 0;
    always #10 clk = !clk;
    reg reset = 1;
    reg restart = 0;
    reg show_bars = 0;
    reg slave_low = 0;
    tri1 scl, sda;
    assign sda = slave_low ? 1'b0 : 1'bz;
    wire configured, failed;
    wire [7:0] pid, version, step;
    reg pclk = 0, href = 0, vsync = 0;
    reg [7:0] camera_data = 0;
    wire pixel_write, frame_done;
    wire [14:0] pixel_address;
    wire [15:0] pixel_data, frame_count;
    wire oled_cs_n, oled_mosi, oled_sclk, oled_dc, oled_reset_n, oled_vccen, oled_pmoden;
    integer x, y, camera_pixels, panel_frame, panel_pixel, panel_bits, command_count;
    integer panel_x, panel_y;
    integer transaction;
    reg [15:0] received, expected_pixel, camera_word;
    reg [7:0] address_byte, addr_high, addr_low, value;
    reg [7:0] registers [0:65535];
    reg [7:0] commands [0:50];
    time panel_powered_at, panel_enabled_at;

    nexys_ov5640 #(.BUS_HZ(2500000), .SETTLE_CYCLES(8)) sensor (
        .clk(clk), .reset(reset), .restart(restart), .configured(configured), .failed(failed),
        .pid(pid), .version(version), .step(step), .scl(scl), .sda(sda)
    );
    camera_dvp_capture #(.WARMUP_FRAMES(0)) capture (
        .clk(clk), .reset(reset), .configured(configured), .freeze(1'b0), .frame_ack(1'b1),
        .pclk(pclk), .href(href), .vsync(vsync), .data(camera_data), .pixel_write(pixel_write),
        .pixel_address(pixel_address), .pixel_data(pixel_data), .frame_done(frame_done),
        .frame_count(frame_count), .timeout_count(), .vsync_count(), .pclk_count(), .line_count(),
        .bad_frame_count(), .state(), .sync_levels()
    );
    nexys_oled_rgb #(.SPI_HALF_CYCLES(2), .LOGIC_POWER_CYCLES(10), .LOGIC_SETTLE_CYCLES(5),
        .PANEL_SETTLE_CYCLES(20), .CLEAR_SETTLE_CYCLES(5)) panel (
        .clk(clk), .reset(reset), .camera_ready(configured), .show_bars(show_bars),
        .pixel_write(pixel_write), .pixel_address(pixel_address), .pixel_data(pixel_data), .frame_done(frame_done),
        .cs_n(oled_cs_n), .mosi(oled_mosi), .sclk(oled_sclk), .dc(oled_dc),
        .reset_n(oled_reset_n), .vccen(oled_vccen), .pmoden(oled_pmoden)
    );

    task await_start;
        begin
            @(negedge sda);
            while (scl !== 1'b1) @(negedge sda);
        end
    endtask

    task await_stop;
        begin
            @(posedge sda);
            while (scl !== 1'b1) @(posedge sda);
        end
    endtask

    task receive_byte;
        output [7:0] rx;
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                @(posedge scl);
                rx[i] = sda;
            end
            @(negedge scl);
            #1 slave_low = 1;
            @(negedge scl);
            #1 slave_low = 0;
        end
    endtask

    task send_byte;
        input [7:0] tx;
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                slave_low = !tx[i];
                @(negedge scl);
                #1;
            end
            slave_low = 0;
            @(posedge scl);
            if (sda !== 1'b1) begin $display("FAIL SCCB read expected NACK"); $finish; end
            @(negedge scl);
        end
    endtask

    initial begin
        for (transaction = 0; transaction < 94; transaction = transaction + 1) begin
            await_start;
            receive_byte(address_byte);
            if (address_byte !== 8'h78) begin $display("FAIL OV5640 write address"); $finish; end
            receive_byte(addr_high);
            receive_byte(addr_low);
            if (transaction < 2) begin
                if ({addr_high, addr_low} !== (transaction == 0 ? 16'h300a : 16'h300b)) begin
                    $display("FAIL OV5640 ID register"); $finish;
                end
                await_start;
                receive_byte(address_byte);
                if (address_byte !== 8'h79) begin $display("FAIL OV5640 read address"); $finish; end
                send_byte(transaction == 0 ? 8'h56 : 8'h40);
            end else begin
                receive_byte(value);
                registers[{addr_high, addr_low}] = value;
            end
            await_stop;
        end
    end

    function [15:0] test_pixel;
        input integer column;
        input integer row;
        begin test_pixel = {column[4:0], row[5:0], column[4:0] ^ row[4:0]}; end
    endfunction

    task dvp_byte;
        input [7:0] data;
        begin
            camera_data = data;
            #65 pclk = 1;
            #65 pclk = 0;
        end
    endtask

    always @(posedge clk) if (pixel_write) begin
        if (pixel_address !== camera_pixels[14:0] ||
            pixel_data !== test_pixel((camera_pixels % 160) * 2, (camera_pixels / 160) * 2)) begin
            $display("FAIL DVP pixel %0d got %h", camera_pixels, pixel_data); $finish;
        end
        camera_pixels = camera_pixels + 1;
    end

    always @(posedge oled_vccen) begin
        if (!oled_pmoden || !oled_reset_n || command_count != 50 || commands[45] !== 8'h25) begin
            $display("FAIL OLED panel power sequence"); $finish;
        end
        panel_powered_at = $time;
    end

    always @(negedge oled_cs_n) begin
        if (!oled_pmoden || !oled_reset_n || oled_sclk !== 1'b1) begin
            $display("FAIL OLED SPI idle or logic power"); $finish;
        end
        received = 0;
        panel_bits = 0;
    end

    always @(posedge oled_sclk) if (!reset) begin
        if (oled_cs_n) begin $display("FAIL OLED clock outside transaction"); $finish; end
        received = {received[14:0], oled_mosi};
        panel_bits = panel_bits + 1;
    end

    always @(posedge oled_cs_n) if (!reset) begin
        if (oled_dc) begin
            if (panel_bits != 16 || command_count != 51 || !oled_vccen || $time - panel_enabled_at < 400) begin
                $display("FAIL OLED RGB565 pixel framing"); $finish;
            end
            panel_x = panel_pixel % 96;
            panel_y = panel_pixel / 96;
            if (panel_frame == 1) begin
                if (panel_x >= 8 && panel_x < 88 && panel_y >= 2 && panel_y < 62)
                    expected_pixel = test_pixel((panel_x - 8) * 4, (panel_y - 2) * 4);
                else expected_pixel = 0;
            end else begin
                case (panel_x / 12)
                    0: expected_pixel = 16'hffff;
                    1: expected_pixel = 16'hffe0;
                    2: expected_pixel = 16'h07ff;
                    3: expected_pixel = 16'h07e0;
                    4: expected_pixel = 16'hf81f;
                    5: expected_pixel = 16'hf800;
                    6: expected_pixel = 16'h001f;
                    default: expected_pixel = 0;
                endcase
            end
            if (received !== expected_pixel) begin
                $display("FAIL OLED frame %0d pixel (%0d,%0d) got %h expected %h",
                         panel_frame, panel_x, panel_y, received, expected_pixel); $finish;
            end
            panel_pixel = panel_pixel + 1;
            if (panel_pixel == 96 * 64) begin
                panel_pixel = 0;
                panel_frame = panel_frame + 1;
            end
        end else begin
            if (panel_bits != 8 || command_count > 50) begin
                $display("FAIL OLED command framing"); $finish;
            end
            if (command_count == 50) begin
                if (received[7:0] !== 8'haf || $time - panel_powered_at < 400) begin
                    $display("FAIL OLED display enabled before panel settled"); $finish;
                end
                panel_enabled_at = $time;
            end
            commands[command_count] = received[7:0];
            command_count = command_count + 1;
        end
    end

    initial begin
        camera_pixels = 0;
        command_count = 0;
        panel_frame = 0;
        panel_pixel = 0;
        repeat (5) @(negedge clk);
        reset = 0;
        wait (configured || failed);
        if (failed || {pid, version} !== 16'h5640 ||
            {registers[16'h3808], registers[16'h3809], registers[16'h380a], registers[16'h380b]} !== 32'h014000f0 ||
            registers[16'h4300] !== 8'h61 || registers[16'h4740] !== 8'h20 || registers[16'h3008] !== 8'h02 ||
            registers[16'h3006] !== 8'hc3 || registers[16'h4202] !== 8'h00 ||
            registers[16'h470b] !== 8'h40 || registers[16'h471d] !== 8'h02) begin
            $display("FAIL OV5640 initialization at step %0d", step); $finish;
        end
        $display("PASS OV5640 SCCB ID, 16-bit registers and QVGA RGB565 setup");
        wait (panel_frame == 1);
        #160;
        if ({commands[2], commands[3], commands[4], commands[39], commands[41], commands[42], commands[44]} !==
            56'haea072155f753f) begin $display("FAIL OLED command values"); $finish; end
        $display("PASS OLED power sequence, command window and 6144 color bar pixels");
        vsync = 1;
        #160 vsync = 0;
        #160;
        for (y = 0; y < 240; y = y + 1) begin
            href = 1;
            #160;
            for (x = 0; x < 320; x = x + 1) begin
                camera_word = test_pixel(x, y);
                dvp_byte(camera_word[15:8]);
                dvp_byte(camera_word[7:0]);
            end
            #160 href = 0;
            #320;
        end
        vsync = 1;
        #160 vsync = 0;
        if (frame_count != 1 || camera_pixels != 19200) begin
            $display("FAIL QVGA frame accounting frames=%0d pixels=%0d", frame_count, camera_pixels); $finish;
        end
        wait (panel_frame == 2);
        @(negedge clk);
        show_bars = 1;
        wait (panel_frame == 3);
        @(negedge clk);
        restart = 1;
        @(negedge clk);
        restart = 0;
        wait (configured || failed);
        if (!failed || configured || step != 0) begin
            $display("FAIL SCCB restart with missing sensor ACK"); $finish;
        end
        $display("PASS OV5640 capture and OLED preview");
        $finish;
    end

    initial begin
        #60000000;
        $display("FAIL camera/OLED simulation timed out step=%0d panel_frame=%0d", step, panel_frame);
        $finish;
    end
endmodule
