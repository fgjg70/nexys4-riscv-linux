`timescale 1ns/1ps

module mig_native_model (
    input wire clk,
    input wire reset,
    input wire stall,
    input wire corrupt_read,
    input wire drop_read,
    input wire bad_end,
    input wire alias_high,
    input wire [26:0] app_addr,
    input wire [2:0] app_cmd,
    input wire app_en,
    output wire app_rdy,
    input wire [127:0] app_wdf_data,
    input wire [15:0] app_wdf_mask,
    input wire app_wdf_end,
    input wire app_wdf_wren,
    output wire app_wdf_rdy,
    output reg [127:0] app_rd_data,
    output reg app_rd_data_valid,
    output reg app_rd_data_end
);
    reg [26:0] tags [0:2047];
    reg [127:0] lines [0:2047];
    reg [127:0] saved_wdata;
    reg [15:0] saved_mask;
    reg write_pending;
    reg read_pending;
    reg [26:0] read_address;
    reg [31:0] cycles;
    integer used_lines, search_index, found_index, byte_index;
    integer read_delay;
    integer reads, writes;
    wire [26:0] mapped_address = alias_high ? app_addr & 27'h1ffffff : app_addr;
    assign app_rdy = !reset && !stall && !read_pending && cycles % 5 != 1;
    assign app_wdf_rdy = !reset && !stall && !write_pending && cycles % 7 != 2;

    always @(posedge clk) begin
        if (reset) begin
            used_lines = 0;
            cycles <= 0;
            reads <= 0;
            writes <= 0;
            write_pending <= 0;
            read_pending <= 0;
            read_delay <= 0;
            app_rd_data <= 0;
            app_rd_data_valid <= 0;
            app_rd_data_end <= 0;
        end else begin
            cycles <= cycles + 1'b1;
            app_rd_data_valid <= 0;
            app_rd_data_end <= 0;
            if (app_wdf_wren && app_wdf_rdy) begin
                if (!app_wdf_end) begin $display("FAIL DDR2 write beat is missing end"); $finish; end
                saved_wdata <= app_wdf_data;
                saved_mask <= app_wdf_mask;
                write_pending <= 1;
            end
            if (app_en && app_rdy) begin
                if (app_addr[2:0] != 0 || app_addr[26]) begin $display("FAIL Invalid DDR2 native address %h", app_addr); $finish; end
                if (app_cmd == 0) begin
                    if (!write_pending) begin $display("FAIL DDR2 write command without buffered data"); $finish; end
                    found_index = -1;
                    for (search_index = 0; search_index < used_lines; search_index = search_index + 1)
                        if (tags[search_index] == mapped_address) found_index = search_index;
                    if (found_index < 0) begin
                        if (used_lines == 2048) begin $display("FAIL Sparse model full"); $finish; end
                        found_index = used_lines;
                        used_lines = used_lines + 1;
                        tags[found_index] = mapped_address;
                        lines[found_index] = 0;
                    end
                    for (byte_index = 0; byte_index < 16; byte_index = byte_index + 1)
                        if (!saved_mask[byte_index])
                            lines[found_index][byte_index * 8 +: 8] = saved_wdata[byte_index * 8 +: 8];
                    write_pending <= 0;
                    writes <= writes + 1;
                end else if (app_cmd == 1) begin
                    read_address <= mapped_address;
                    read_pending <= 1;
                    read_delay <= 4;
                end else begin $display("FAIL Unexpected DDR2 command"); $finish; end
            end
            if (read_pending && !drop_read) begin
                if (read_delay != 0) read_delay <= read_delay - 1;
                else begin
                    found_index = -1;
                    for (search_index = 0; search_index < used_lines; search_index = search_index + 1)
                        if (tags[search_index] == read_address) found_index = search_index;
                    app_rd_data <= (found_index < 0 ? 128'd0 : lines[found_index]) ^ (corrupt_read ? 128'd1 : 128'd0);
                    app_rd_data_valid <= 1;
                    app_rd_data_end <= !bad_end;
                    read_pending <= 0;
                    reads <= reads + 1;
                end
            end
        end
    end
endmodule
