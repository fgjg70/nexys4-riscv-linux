`timescale 1ns/1ps
module nexys_ps2_keyboard (
    input wire clk, input wire reset, input wire ps2_clk, input wire ps2_data,
    output reg [7:0] scan_code, output reg valid
);
    (* ASYNC_REG = "TRUE" *) reg [2:0] clk_sync, data_sync;
    reg [3:0] count;
    reg [10:0] bits;
    reg [19:0] timeout;
    always @(posedge clk) begin
        clk_sync <= {clk_sync[1:0], ps2_clk};
        data_sync <= {data_sync[1:0], ps2_data};
        valid <= 0;
        if (reset) begin
            clk_sync <= 3'b111;
            data_sync <= 3'b111;
            count <= 0;
            timeout <= 0;
            bits <= 0;
            scan_code <= 0;
        end else begin
            if (count != 0) begin
                if (&timeout) begin count <= 0; timeout <= 0; end
                else timeout <= timeout + 1'b1;
            end
            if (clk_sync[2:1] == 2'b10) begin
                timeout <= 0;
                bits[count] <= data_sync[2];
                if (count == 10) begin
                    count <= 0;
                    if (!bits[0] && data_sync[2] && (^bits[9:1])) begin
                        scan_code <= bits[8:1];
                        valid <= 1;
                    end
                end else count <= count + 1'b1;
            end
        end
    end
endmodule
