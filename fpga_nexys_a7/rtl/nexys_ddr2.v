`timescale 1ns/1ps

module nexys_ddr2 #(
    parameter integer BIST_TEST_WORDS = 1024
) (
    input wire ref_clk200,
    input wire clk,
    input wire reset,
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
    wire ui_clk, ui_reset, initialized;
    wire [26:0] app_addr;
    wire [2:0] app_cmd;
    wire app_en, app_rdy, app_wdf_end, app_wdf_wren, app_wdf_rdy;
    wire [127:0] app_wdf_data, app_rd_data;
    wire [15:0] app_wdf_mask;
    wire app_rd_data_valid, app_rd_data_end;
    ddr mig (
        .sys_clk_i(ref_clk200), .sys_rst(!reset), .ui_clk(ui_clk), .ui_clk_sync_rst(ui_reset),
        .init_calib_complete(initialized), .ddr2_addr(ddr2_addr), .ddr2_ba(ddr2_ba),
        .ddr2_ras_n(ddr2_ras_n), .ddr2_cas_n(ddr2_cas_n), .ddr2_we_n(ddr2_we_n),
        .ddr2_ck_p(ddr2_ck_p), .ddr2_ck_n(ddr2_ck_n), .ddr2_cke(ddr2_cke),
        .ddr2_cs_n(ddr2_cs_n), .ddr2_dm(ddr2_dm), .ddr2_odt(ddr2_odt),
        .ddr2_dq(ddr2_dq), .ddr2_dqs_p(ddr2_dqs_p), .ddr2_dqs_n(ddr2_dqs_n),
        .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en), .app_rdy(app_rdy),
        .app_wdf_data(app_wdf_data), .app_wdf_mask(app_wdf_mask),
        .app_wdf_end(app_wdf_end), .app_wdf_wren(app_wdf_wren), .app_wdf_rdy(app_wdf_rdy),
        .app_rd_data(app_rd_data), .app_rd_data_valid(app_rd_data_valid), .app_rd_data_end(app_rd_data_end),
        .app_sr_req(1'b0), .app_ref_req(1'b0), .app_zq_req(1'b0),
        .app_sr_active(), .app_ref_ack(), .app_zq_ack()
    );
    nexys_ddr2_memory #(.BIST_TEST_WORDS(BIST_TEST_WORDS)) memory (
        .system_clk(clk), .system_reset(reset), .ui_clk(ui_clk), .ui_reset(ui_reset), .initialized(initialized),
        .memory_read(memory_read), .memory_write(memory_write), .memory_address(memory_address),
        .memory_wdata(memory_wdata), .memory_wstrb(memory_wstrb), .memory_ready(memory_ready),
        .memory_rdata(memory_rdata), .memory_status(memory_status),
        .error_address(error_address), .error_expected(error_expected), .error_actual(error_actual),
        .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en), .app_rdy(app_rdy),
        .app_wdf_data(app_wdf_data), .app_wdf_mask(app_wdf_mask),
        .app_wdf_end(app_wdf_end), .app_wdf_wren(app_wdf_wren), .app_wdf_rdy(app_wdf_rdy),
        .app_rd_data(app_rd_data), .app_rd_data_valid(app_rd_data_valid), .app_rd_data_end(app_rd_data_end)
    );
endmodule
