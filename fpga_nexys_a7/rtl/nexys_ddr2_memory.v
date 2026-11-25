`timescale 1ns/1ps

module nexys_ddr2_memory #(
    parameter integer BIST_TEST_WORDS = 1024,
    parameter integer TIMEOUT_CYCLES = 75000000
) (
    input wire system_clk,
    input wire system_reset,
    input wire ui_clk,
    input wire ui_reset,
    input wire initialized,
    input wire memory_read,
    input wire memory_write,
    input wire [31:0] memory_address,
    input wire [31:0] memory_wdata,
    input wire [3:0] memory_wstrb,
    output wire memory_ready,
    output wire [31:0] memory_rdata,
    output wire [31:0] memory_status,
    output wire [31:0] error_address,
    output wire [31:0] error_expected,
    output wire [31:0] error_actual,
    output wire [26:0] app_addr,
    output wire [2:0] app_cmd,
    output wire app_en,
    input wire app_rdy,
    output wire [127:0] app_wdf_data,
    output wire [15:0] app_wdf_mask,
    output wire app_wdf_end,
    output wire app_wdf_wren,
    input wire app_wdf_rdy,
    input wire [127:0] app_rd_data,
    input wire app_rd_data_valid,
    input wire app_rd_data_end
);
    wire ui_read, ui_write;
    wire [31:0] ui_address, ui_wdata;
    wire [3:0] ui_wstrb;
    wire bist_read, bist_write, bist_busy, bist_done, bist_passed;
    wire [31:0] bist_address, bist_wdata;
    wire [3:0] bist_wstrb;
    wire [31:0] bist_error_address, bist_error_expected, bist_error_actual;
    reg bist_started;
    reg bist_start;
    wire port_ready, port_fault, response_fault;
    wire [31:0] port_rdata;
    wire accessible = initialized && bist_done && bist_passed && !bist_busy;
    wire rejected = !initialized || (bist_done && !bist_passed) || port_fault;
    wire [6:0] ui_status = {bist_done && !bist_passed, bist_busy, port_fault,
        bist_done, bist_passed, initialized, 1'b1};
    (* ASYNC_REG = "TRUE" *) reg [102:0] status_meta;
    (* ASYNC_REG = "TRUE" *) reg [102:0] status_sync;
    (* ASYNC_REG = "TRUE" *) reg [2:0] crossing_reset_sync;
    wire crossing_reset_request = system_reset || ui_reset;
    wire crossing_reset = crossing_reset_sync[2];
    assign {error_address, error_expected, error_actual, memory_status} =
        {status_sync[102:7], 25'd0, status_sync[6:0]};

    always @(posedge system_clk or posedge crossing_reset_request) begin
        if (crossing_reset_request) crossing_reset_sync <= 3'b111;
        else crossing_reset_sync <= {crossing_reset_sync[1:0], 1'b0};
    end
    always @(posedge system_clk or posedge system_reset) begin
        if (system_reset) begin status_meta <= 0; status_sync <= 0; end
        else begin
            status_meta <= {bist_error_address, bist_error_expected, bist_error_actual, ui_status};
            status_sync <= status_meta;
        end
    end
    always @(posedge ui_clk or posedge ui_reset) begin
        if (ui_reset) begin bist_started <= 0; bist_start <= 0; end
        else begin
            bist_start <= 0;
            if (initialized && !bist_started) begin bist_started <= 1; bist_start <= 1; end
        end
    end
    vision_mmio_bridge #(.WAIT_PERIPHERAL(1)) crossing (
        .cpu_clk(system_clk), .cpu_reset(crossing_reset),
        .cpu_write(memory_write), .cpu_read(memory_read), .cpu_address(memory_address),
        .cpu_wdata(memory_wdata), .cpu_wstrb(memory_wstrb), .cpu_ready(memory_ready),
        .response_data(memory_rdata), .peripheral_clk(ui_clk), .peripheral_reset(ui_reset),
        .peripheral_write(ui_write), .peripheral_read(ui_read), .peripheral_address(ui_address),
        .peripheral_wdata(ui_wdata), .peripheral_wstrb(ui_wstrb),
        .peripheral_rdata(rejected ? 32'hdd200bad : port_rdata),
        .peripheral_ready(rejected || (accessible && port_ready))
    );
    nexys_ddr2_bist #(.TEST_WORDS(BIST_TEST_WORDS)) selftest (
        .clk(ui_clk), .reset(ui_reset), .start(bist_start),
        .request_read(bist_read), .request_write(bist_write), .request_address(bist_address),
        .request_wdata(bist_wdata), .request_wstrb(bist_wstrb), .request_ready(port_ready),
        .response_data(port_rdata), .response_fault(response_fault),
        .busy(bist_busy), .done(bist_done), .passed(bist_passed),
        .error_address(bist_error_address), .error_expected(bist_error_expected), .error_actual(bist_error_actual)
    );
    nexys_ddr2_port #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) port (
        .clk(ui_clk), .reset(ui_reset), .initialized(initialized),
        .request_read(accessible ? ui_read : bist_read), .request_write(accessible ? ui_write : bist_write),
        .request_address(accessible ? ui_address : bist_address),
        .request_wdata(accessible ? ui_wdata : bist_wdata), .request_wstrb(accessible ? ui_wstrb : bist_wstrb),
        .request_ready(port_ready), .response_data(port_rdata), .response_fault(response_fault), .fault(port_fault),
        .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en), .app_rdy(app_rdy),
        .app_wdf_data(app_wdf_data), .app_wdf_mask(app_wdf_mask),
        .app_wdf_end(app_wdf_end), .app_wdf_wren(app_wdf_wren), .app_wdf_rdy(app_wdf_rdy),
        .app_rd_data(app_rd_data), .app_rd_data_valid(app_rd_data_valid), .app_rd_data_end(app_rd_data_end)
    );
endmodule
