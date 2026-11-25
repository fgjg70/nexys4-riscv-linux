`timescale 1ns/1ps

module nexys_clocks (
    input wire clk100,
    input wire reset,
    output wire clk50,
    output wire clk60,
    output wire clk25,
    output wire clk200,
    output wire locked
);
    wire input_clock;
    wire feedback;
    wire feedback_buffered;
    wire clock50;
    wire clock60;
    wire clock25;
    wire clock200;
    IBUF input_buffer (.I(clk100), .O(input_clock));
    BUFG feedback_buffer (.I(feedback), .O(feedback_buffered));
    BUFG system_buffer (.I(clock50), .O(clk50));
    BUFG cpu_buffer (.I(clock60), .O(clk60));
    BUFG video_buffer (.I(clock25), .O(clk25));
    BUFG reference_buffer (.I(clock200), .O(clk200));
    MMCME2_BASE #(
        .CLKIN1_PERIOD(10.0), .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(12.0),
        .CLKOUT0_DIVIDE_F(24.0), .CLKOUT1_DIVIDE(20), .CLKOUT2_DIVIDE(48),
        .CLKOUT3_DIVIDE(6), .STARTUP_WAIT("FALSE")
    ) mmcm (
        .CLKIN1(input_clock), .CLKFBIN(feedback_buffered), .CLKFBOUT(feedback),
        .CLKOUT0(clock50), .CLKOUT1(clock60), .CLKOUT2(clock25), .CLKOUT3(clock200),
        .LOCKED(locked), .PWRDWN(1'b0), .RST(reset)
    );
endmodule
