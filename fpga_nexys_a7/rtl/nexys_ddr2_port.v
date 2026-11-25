`timescale 1ns/1ps

module nexys_ddr2_port #(
    parameter integer TIMEOUT_CYCLES = 75000000
) (
    input wire clk,
    input wire reset,
    input wire initialized,
    input wire request_read,
    input wire request_write,
    input wire [31:0] request_address,
    input wire [31:0] request_wdata,
    input wire [3:0] request_wstrb,
    output wire request_ready,
    output reg [31:0] response_data,
    output reg response_fault,
    output reg fault,
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
    localparam IDLE = 0, WRITE_DATA = 1, COMMAND = 2, READ_DATA = 3, RESPONSE = 4;
    reg [2:0] state;
    reg [31:0] held_address;
    reg [31:0] held_wdata;
    reg [3:0] held_wstrb;
    reg held_write;
    reg [31:0] wait_cycles;
    wire active = state == WRITE_DATA || state == COMMAND || state == READ_DATA;
    wire invalid_request = request_address[31:27] != 0 || request_address[1:0] != 0 ||
        (request_read && request_write);

    assign request_ready = state == RESPONSE;
    assign app_addr = {1'b0, held_address[26:4], 3'b000};
    assign app_cmd = held_write ? 3'b000 : 3'b001;
    assign app_en = state == COMMAND && initialized && !fault;
    assign app_wdf_data = {96'd0, held_wdata} << (held_address[3:2] * 32);
    assign app_wdf_mask = ~({12'd0, held_wstrb} << (held_address[3:2] * 4));
    assign app_wdf_end = app_wdf_wren;
    assign app_wdf_wren = state == WRITE_DATA && initialized && !fault;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            held_address <= 0;
            held_wdata <= 0;
            held_wstrb <= 0;
            held_write <= 0;
            wait_cycles <= 0;
            response_data <= 0;
            response_fault <= 0;
            fault <= 0;
        end else begin
            if (active) wait_cycles <= wait_cycles + 1'b1;
            else wait_cycles <= 0;
            if (active && (!initialized || wait_cycles == TIMEOUT_CYCLES - 1)) begin
                state <= RESPONSE;
                response_data <= 32'hdd200bad;
                response_fault <= 1;
                fault <= 1;
            end else begin
                case (state)
                    IDLE: if (request_read || request_write) begin
                        held_address <= request_address;
                        held_wdata <= request_wdata;
                        held_wstrb <= request_wstrb;
                        held_write <= request_write;
                        response_data <= 0;
                        response_fault <= 0;
                        if (!initialized || fault || invalid_request) begin
                            response_data <= 32'hdd200bad;
                            response_fault <= 1;
                            state <= RESPONSE;
                        end else if (request_write && request_wstrb == 0) state <= RESPONSE;
                        else state <= request_write ? WRITE_DATA : COMMAND;
                    end
                    WRITE_DATA: if (app_wdf_rdy) begin
                        state <= COMMAND;
                        wait_cycles <= 0;
                    end
                    COMMAND: if (app_rdy) begin
                        state <= held_write ? RESPONSE : READ_DATA;
                        wait_cycles <= 0;
                    end
                    READ_DATA: if (app_rd_data_valid) begin
                        response_data <= app_rd_data[held_address[3:2] * 32 +: 32];
                        response_fault <= !app_rd_data_end;
                        fault <= !app_rd_data_end;
                        state <= RESPONSE;
                    end
                    RESPONSE: if (!request_read && !request_write) state <= IDLE;
                    default: state <= IDLE;
                endcase
            end
        end
    end
endmodule
