`timescale 1ns/1ps

module nexys_ov5640 #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer BUS_HZ = 100000,
    parameter integer SETTLE_CYCLES = CLOCK_HZ / 50
) (
    input wire clk,
    input wire reset,
    input wire restart,
    output reg configured,
    output reg failed,
    output reg [7:0] pid,
    output reg [7:0] version,
    output reg [7:0] step,
    output wire scl,
    inout wire sda
);
    localparam [1:0] SETTLE=0, ISSUE=1, WAIT_BUS=2, COMPLETE=3;
    localparam [7:0] SOFT_RESET = 3, STREAM_ON = 93;
    localparam integer TIMER_BITS = SETTLE_CYCLES < 2 ? 1 : $clog2(SETTLE_CYCLES);
    reg [1:0] state;
    reg [TIMER_BITS-1:0] timer;
    reg start;
    wire done, error, scl_level;
    wire [7:0] read_data;
    wire [23:0] command = settings(step);

    assign scl = scl_level ? 1'bz : 1'b0;
    camera_sccb #(.CLOCK_HZ(CLOCK_HZ), .BUS_HZ(BUS_HZ),
        .REGISTER_BITS(16), .DEVICE_ADDRESS(7'h3c)) bus (
        .clk(clk), .reset(reset || restart), .start(start),
        .read_enable(step < 2), .register_address(command[23:8]), .write_data(command[7:0]),
        .busy(), .done(done), .error(error), .read_data(read_data), .scl(scl_level), .sda(sda)
    );

    function [23:0] settings(input [7:0] index);
        begin
            case (index)
                0:  settings = 24'h300a00; // Chip ID high
                1:  settings = 24'h300b00; // Chip ID low
                2:  settings = 24'h310311; // Clock source before reset
                3:  settings = 24'h300882;
                4:  settings = 24'h300842; // Stay in software standby during configuration
                5:  settings = 24'h310303;
                6:  settings = 24'h30341a;
                7:  settings = 24'h303541;
                8:  settings = 24'h303646;
                9:  settings = 24'h303713;
                10: settings = 24'h310801;
                // Analog and sensor timing settings for the binned DVP mode.
                11: settings = 24'h363036;
                12: settings = 24'h36310e;
                13: settings = 24'h3632e2;
                14: settings = 24'h363312;
                15: settings = 24'h3621e0;
                16: settings = 24'h3704a0;
                17: settings = 24'h37035a;
                18: settings = 24'h371578;
                19: settings = 24'h371701;
                20: settings = 24'h370b60;
                21: settings = 24'h37051a;
                22: settings = 24'h390502;
                23: settings = 24'h390610;
                24: settings = 24'h39010a;
                25: settings = 24'h373112;
                26: settings = 24'h360008;
                27: settings = 24'h360133;
                28: settings = 24'h302d60;
                29: settings = 24'h362052;
                30: settings = 24'h371b20;
                31: settings = 24'h471c50;
                32: settings = 24'h361800;
                33: settings = 24'h361229;
                34: settings = 24'h370864;
                35: settings = 24'h370952;
                36: settings = 24'h370c03;
                37: settings = 24'h363513;
                38: settings = 24'h363603;
                39: settings = 24'h363440;
                40: settings = 24'h362201;
                // Binned 4:3 sensor window, with the ISP scaler set to 320x240.
                41: settings = 24'h382041;
                42: settings = 24'h382107;
                43: settings = 24'h381431;
                44: settings = 24'h381531;
                45: settings = 24'h380000;
                46: settings = 24'h380100;
                47: settings = 24'h380200;
                48: settings = 24'h380304;
                49: settings = 24'h38040a;
                50: settings = 24'h38053f;
                51: settings = 24'h380607;
                52: settings = 24'h38079b;
                53: settings = 24'h380801;
                54: settings = 24'h380940;
                55: settings = 24'h380a00;
                56: settings = 24'h380bf0;
                57: settings = 24'h380c07;
                58: settings = 24'h380d68;
                59: settings = 24'h380e03;
                60: settings = 24'h380fd8;
                61: settings = 24'h381110;
                62: settings = 24'h381306;
                63: settings = 24'h400102;
                64: settings = 24'h400402;
                65: settings = 24'h500027;
                66: settings = 24'h5001a3;
                67: settings = 24'h350300;
                // RGB565 high byte first, explicit DVP polarities, divided PCLK.
                68: settings = 24'h430061;
                69: settings = 24'h501f01;
                70: settings = 24'h300e18;
                71: settings = 24'h30177f;
                72: settings = 24'h3018fc;
                73: settings = 24'h474020; // Rising-edge PCLK, active-high HREF and VSYNC
                74: settings = 24'h460b35;
                75: settings = 24'h460c23;
                76: settings = 24'h382404;
                77: settings = 24'h40051a;
                78: settings = 24'h503d00;
                // Release the ISP blocks and start the parallel output path.
                79: settings = 24'h300000;
                80: settings = 24'h30021c;
                81: settings = 24'h3004ff;
                82: settings = 24'h3006c3;
                83: settings = 24'h302e00;
                84: settings = 24'h471303;
                85: settings = 24'h440704;
                86: settings = 24'h440e00;
                87: settings = 24'h473000;
                88: settings = 24'h420200;
                // Generate a finite VSYNC pulse and qualify the active RGB565 bytes with HREF.
                89: settings = 24'h470904;
                90: settings = 24'h470a00;
                91: settings = 24'h470b40;
                92: settings = 24'h471d02;
                STREAM_ON: settings = 24'h300802;
                default: settings = 0;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (reset || restart) begin
            state <= SETTLE;
            timer <= SETTLE_CYCLES - 1;
            step <= 0;
            start <= 0;
            configured <= 0;
            failed <= 0;
            pid <= 0;
            version <= 0;
        end else begin
            start <= 0;
            case (state)
                SETTLE: if (timer == 0) state <= ISSUE;
                        else timer <= timer - 1'b1;
                ISSUE: begin
                    start <= 1;
                    state <= WAIT_BUS;
                end
                WAIT_BUS: if (done) begin
                    if (step == 0) pid <= read_data;
                    if (step == 1) version <= read_data;
                    if (error || (step == 1 && {pid, read_data} != 16'h5640)) begin
                        failed <= 1;
                        state <= COMPLETE;
                    end else if (step == STREAM_ON) begin
                        configured <= 1;
                        state <= COMPLETE;
                    end else begin
                        step <= step + 1'b1;
                        if (step == SOFT_RESET) begin
                            timer <= SETTLE_CYCLES - 1;
                            state <= SETTLE;
                        end else state <= ISSUE;
                    end
                end
                default: state <= COMPLETE;
            endcase
        end
    end
endmodule
