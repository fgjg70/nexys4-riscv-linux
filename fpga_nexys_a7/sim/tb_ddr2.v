`timescale 1ns/1ps

module tb_ddr2 #(
    parameter integer RUN_CPU = 0
);
    reg system_clk = 0;
    reg cpu_clk = 0;
    reg ui_clk = 0;
    always #10 system_clk = !system_clk;
    always #8.333333 cpu_clk = !cpu_clk;
    always #6.666 ui_clk = !ui_clk;
    reg reset = 1;
    reg initialized = 0;
    reg stall = 0, corrupt_read = 0, drop_read = 0, bad_end = 0, alias_high = 0;
    reg host_read = 0, host_write = 0;
    reg [31:0] host_address = 0, host_wdata = 0;
    reg [3:0] host_wstrb = 0;
    wire memory_read, memory_write, memory_ready;
    wire [31:0] memory_address, memory_wdata, memory_rdata, memory_status;
    wire [31:0] error_address, error_expected, error_actual;
    wire [3:0] memory_wstrb;
    wire [26:0] app_addr;
    wire [2:0] app_cmd;
    wire app_en, app_rdy, app_wdf_end, app_wdf_wren, app_wdf_rdy;
    wire [127:0] app_wdf_data, app_rd_data;
    wire [15:0] app_wdf_mask;
    wire app_rd_data_valid, app_rd_data_end;
    integer wait_cycles, case_index, lane_index, strobes, reads_before, writes_before;
    reg [31:0] observed, expected, hits, misses;

    vision_soc #(.MEMORY_ENABLE(1), .MEMORY_BYTES(32'h08000000), .MODEL_MASK(3)) soc (
        .clk(system_clk), .reset(reset), .cpu_clk(cpu_clk), .cpu_reset(reset),
        .keys_n(4'hf), .uart_rxd(1'b1), .uart_txd(), .servo_pwm(),
        .memory_read(memory_read), .memory_write(memory_write), .memory_address(memory_address),
        .memory_wdata(memory_wdata), .memory_wstrb(memory_wstrb), .memory_ready(memory_ready),
        .memory_rdata(memory_rdata), .memory_status(memory_status),
        .memory_error_address(error_address), .memory_error_expected(error_expected), .memory_error_actual(error_actual),
        .configured(1'b0), .failed(1'b0), .frame_valid(1'b0), .frame_count(16'd0),
        .frame_tick(1'b0), .pixel_write(1'b0), .pixel_address(15'd0), .pixel_data(16'd0),
        .frame_done(1'b0), .frozen(), .show_bars(), .restart(), .overlay_valid(), .extra_boxes(),
        .box_left(), .box_top(), .box_right(), .box_bottom(), .label(), .panel_status(),
        .pass_count(), .reject_count(), .inference_busy(), .benchmark_result(), .cpu_illegal()
    );
    nexys_ddr2_memory #(.BIST_TEST_WORDS(16), .TIMEOUT_CYCLES(64)) memory (
        .system_clk(system_clk), .system_reset(reset), .ui_clk(ui_clk), .ui_reset(reset),
        .initialized(initialized), .memory_read(memory_read), .memory_write(memory_write),
        .memory_address(memory_address), .memory_wdata(memory_wdata), .memory_wstrb(memory_wstrb),
        .memory_ready(memory_ready), .memory_rdata(memory_rdata), .memory_status(memory_status),
        .error_address(error_address), .error_expected(error_expected), .error_actual(error_actual),
        .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en), .app_rdy(app_rdy),
        .app_wdf_data(app_wdf_data), .app_wdf_mask(app_wdf_mask), .app_wdf_end(app_wdf_end),
        .app_wdf_wren(app_wdf_wren), .app_wdf_rdy(app_wdf_rdy), .app_rd_data(app_rd_data),
        .app_rd_data_valid(app_rd_data_valid), .app_rd_data_end(app_rd_data_end)
    );
    mig_native_model model (
        .clk(ui_clk), .reset(reset), .stall(stall), .corrupt_read(corrupt_read), .drop_read(drop_read),
        .bad_end(bad_end), .alias_high(alias_high), .app_addr(app_addr), .app_cmd(app_cmd),
        .app_en(app_en), .app_rdy(app_rdy), .app_wdf_data(app_wdf_data), .app_wdf_mask(app_wdf_mask),
        .app_wdf_end(app_wdf_end), .app_wdf_wren(app_wdf_wren), .app_wdf_rdy(app_wdf_rdy),
        .app_rd_data(app_rd_data), .app_rd_data_valid(app_rd_data_valid), .app_rd_data_end(app_rd_data_end)
    );

    task transact;
        input write_request;
        input [31:0] address;
        input [31:0] value;
        input [3:0] mask;
        output [31:0] result;
        begin
            @(negedge cpu_clk);
            host_address = address;
            host_wdata = value;
            host_wstrb = mask;
            host_write = write_request;
            host_read = !write_request;
            wait_cycles = 0;
            while (!soc.cpu_ready && wait_cycles < 4000) begin
                @(negedge cpu_clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!soc.cpu_ready) begin $display("FAIL CPU bus timeout at %h", address); $finish; end
            result = soc.cpu_rdata;
            host_read = 0;
            host_write = 0;
            @(negedge cpu_clk);
        end
    endtask
    task write_word;
        input [31:0] address;
        input [31:0] value;
        begin transact(1'b1, address, value, 4'hf, observed); end
    endtask
    task expect_word;
        input [31:0] address;
        input [31:0] value;
        begin
            transact(1'b0, address, 0, 0, observed);
            if (observed !== value) begin $display("FAIL Address %h expected %h actual %h", address, value, observed); $finish; end
        end
    endtask
    task reset_design;
        begin
            reset = 1;
            initialized = 0;
            repeat (12) @(negedge system_clk);
            reset = 0;
            repeat (12) @(negedge system_clk);
        end
    endtask
    task wait_bist;
        begin
            wait_cycles = 0;
            while (!memory_status[3] && wait_cycles < 10000) begin
                @(negedge system_clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!memory_status[3]) begin $display("FAIL DDR2 BIST did not complete"); $finish; end
        end
    endtask

    initial begin
        if (!RUN_CPU) begin
            force soc.cpu_read = host_read;
            force soc.cpu_write = host_write;
            force soc.cpu_address = host_address;
            force soc.cpu_wdata = host_wdata;
            force soc.cpu_wstrb = host_wstrb;
        end
        reset_design();
        if (RUN_CPU) begin
            initialized = 1;
            wait_cycles = 0;
            while (soc.benchmark_done == 0 && wait_cycles < 400000) begin
                @(negedge system_clk);
                wait_cycles = wait_cycles + 1;
            end
            if (soc.benchmark_done != 32'h600d600d || soc.cpu_illegal)
                begin $display("FAIL Real CPU DDR2 test failed result=%h illegal=%b", soc.benchmark_done, soc.cpu_illegal); $finish; end
            $display("PASS real RV32 CPU DDR2 execution result=%h cycles=%0d", soc.benchmark_done, wait_cycles);
            $finish;
        end
        expect_word(32'ha1000064, 32'd3);
        $display("PASS both model banks accessible through MMIO");
        expect_word(32'ha100009c, 32'h08000000);
        expect_word(32'hc0000000, 32'hdd200bad);
        write_word(32'ha1000100, 0);
        initialized = 1;
        wait_bist();
        if (memory_status != 15) begin $display("FAIL DDR2 BIST failed status=%h", memory_status); $finish; end
        $display("PASS DDR2 calibration gate and boundary BIST");

        write_word(32'hc0000000, 32'h13579bdf);
        write_word(32'hc2000000, 32'h2468ace0);
        write_word(32'hc4000000, 32'h12345678);
        write_word(32'hc6000000, 32'h99887766);
        write_word(32'hc7fffffc, 32'h88776655);
        write_word(32'ha1000100, 5);
        expect_word(32'hc0000000, 32'h13579bdf);
        expect_word(32'hc0000000, 32'h13579bdf);
        expect_word(32'hc2000000, 32'h2468ace0);
        expect_word(32'hc2000000, 32'h2468ace0);
        expect_word(32'hc4000000, 32'h12345678);
        expect_word(32'hc4000000, 32'h12345678);
        expect_word(32'hc6000000, 32'h99887766);
        expect_word(32'hc6000000, 32'h99887766);
        expect_word(32'hc7fffffc, 32'h88776655);
        expect_word(32'hc7fffffc, 32'h88776655);
        transact(0, 32'ha1000104, 0, 0, hits);
        transact(0, 32'ha1000108, 0, 0, misses);
        if (hits < 5 || misses < 5) begin $display("FAIL Cache statistics invalid"); $finish; end
        write_word(32'ha1000100, 0);
        reads_before = model.reads;
        writes_before = model.writes;
        expect_word(32'hc8000000, 32'hdd200bad);
        write_word(32'hc8000000, 32'hfeedface);
        expect_word(32'hfffffffc, 32'hdd200bad);
        expect_word(32'hc0000002, 32'hdd200bad);
        if (model.reads != reads_before || model.writes != writes_before)
            begin $display("FAIL Out of range or unaligned request reached MIG"); $finish; end
        expect_word(32'hc0000000, 32'h13579bdf);
        $display("PASS capacity, cache tags and out of range rejection");

        for (lane_index = 0; lane_index < 4; lane_index = lane_index + 1) begin
            for (strobes = 0; strobes < 16; strobes = strobes + 1) begin
                write_word(32'hc0000100 + lane_index * 4, 32'h11223344);
                transact(1, 32'hc0000100 + lane_index * 4, 32'h89abcdef, strobes[3:0], observed);
                expected = 32'h11223344;
                if (strobes[0]) expected[7:0] = 8'hef;
                if (strobes[1]) expected[15:8] = 8'hcd;
                if (strobes[2]) expected[23:16] = 8'hab;
                if (strobes[3]) expected[31:24] = 8'h89;
                expect_word(32'hc0000100 + lane_index * 4, expected);
            end
        end
        $display("PASS all 64 DDR2 byte masks and burst word positions");
        for (case_index = 1; case_index <= 5; case_index = case_index + 1) begin
            stall = case_index == 1;
            corrupt_read = case_index == 2;
            drop_read = case_index == 3;
            bad_end = case_index == 4;
            alias_high = case_index == 5;
            reset_design();
            initialized = 1;
            wait_bist();
            if (memory_status[2] || !memory_status[6]) begin $display("FAIL BIST accepted fault case %0d", case_index); $finish; end
            expect_word(32'hc0000000, 32'hdd200bad);
            $display("PASS fault case=%0d status=%h address=%h", case_index, memory_status, error_address);
        end
        stall = 0; corrupt_read = 0; drop_read = 0; bad_end = 0; alias_high = 0;
        reset_design();
        initialized = 1;
        wait_bist();
        write_word(32'ha1000100, 0);
        initialized = 0;
        expect_word(32'hc0000000, 32'hdd200bad);
        $display("PASS calibration loss rejection");
        $display("PASS all integrated DDR2 bus tests");
        $finish;
    end
    initial begin
        #20000000;
        begin $display("FAIL DDR2 simulation watchdog expired"); $finish; end
    end
endmodule

module tb_ddr2_cpu;
    tb_ddr2 #(.RUN_CPU(1)) test();
endmodule
