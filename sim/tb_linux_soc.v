`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// tb_linux_soc.v — 统一主存 + 4 KB VIPT I/D-Cache + CLINT/PLIC/16550 端到端测试台
// 纯 Verilog-2001，挂接 256 KB 行为统一 RAM (含可配多拍延迟以压测 Cache 填充/回写)。
// ----------------------------------------------------------------------------
// plusarg:
//   +ram=<hex>         加载至 0x8000_0000 的统一镜像 (每行 32-bit hex)
//   +max_cycles=<N>    最大仿真周期 (默认 500000)
//   +ram_lat=<N>       模拟 DDR2 单字响应延迟拍数 (默认 3 拍)
// 结束协议: 软件通过非缓存/缓存写 tohost (0x8003_F000): 1=PASS, 其它=FAIL。
// 注意: 因 D-Cache 为回写缓存，测试固件在写完 tohost 后执行 fence.i 清洗回主存。
// ============================================================================

module tb_linux_soc;
  localparam TCLK_HALF    = 10;              // 50 MHz (ns)
  localparam RAM_WORDS    = 65536;           // 256 KB 统一 RAM (0x8000_0000 .. 0x8003_FFFF)
  localparam TOHOST_IDX   = 32'h0003_F000 / 4;

  reg        clk;
  reg        rst;
  reg [31:0] cycles;
  reg [31:0] max_cycles;
  integer    ram_lat;

  initial begin
    clk        = 1'b0;
    rst        = 1'b1;
    cycles     = 32'd0;
    max_cycles = 32'd500000;
    ram_lat    = 3;
  end
  always #(TCLK_HALF) clk = ~clk;

  // SoC <-> 行为统一 RAM 接口
  wire        ram_req, ram_we;
  wire [31:0] ram_addr, ram_wdata;
  wire [3:0]  ram_wstrb;
  reg         ram_ack;
  reg  [31:0] ram_rdata;
  reg         ram_err;

  wire        uart_txd;
  wire [31:0] dbg_pc, dbg_id_pc, dbg_instr;
  wire        dbg_illegal;
  wire        uart_tx_pulse;
  wire [7:0]  uart_tx_byte;

  rv32_soc #(
    .RESET_PC       (`SOC_ROM_BASE),
    .CLK_HZ         (50_000_000),
    .BAUD_HZ        (115_200),
    .CLINT_TICK_DIV (1)
  ) u_soc (
    .clk           (clk),
    .rst           (rst),
    .ram_req       (ram_req),
    .ram_we        (ram_we),
    .ram_addr      (ram_addr),
    .ram_wdata     (ram_wdata),
    .ram_wstrb     (ram_wstrb),
    .ram_ack       (ram_ack),
    .ram_rdata     (ram_rdata),
    .ram_err       (ram_err),
    .uart_txd      (uart_txd),
    .uart_rxd      (1'b1),
    .ext_irq_in    (6'd0),
    .dbg_pc        (dbg_pc),
    .dbg_id_pc     (dbg_id_pc),
    .dbg_instr     (dbg_instr),
    .dbg_illegal   (dbg_illegal),
    .uart_tx_pulse (uart_tx_pulse),
    .uart_tx_byte  (uart_tx_byte)
  );

  // ---- 256 KB 行为统一 RAM (带可配多拍延迟，压测 I/D-Cache 与总线仲裁) ----
  reg [31:0] ram_mem [0:RAM_WORDS-1];
  reg        ram_pend;
  integer    ram_cnt;
  reg [31:0] ram_addr_q, ram_wdata_q;
  reg [3:0]  ram_wstrb_q;
  reg        ram_we_q;

  wire [31:0] ram_off = ram_addr - `SOC_RAM_BASE;
  wire [31:0] ram_off_q = ram_addr_q - `SOC_RAM_BASE;

  integer i;
  reg [8*256-1:0] ram_file;
  integer rc;

  initial begin
    for (i = 0; i < RAM_WORDS; i = i + 1) ram_mem[i] = 32'd0;
    if ($value$plusargs("ram=%s", ram_file)) begin
      $readmemh(ram_file, ram_mem);
      $display("[tb_linux_soc] loaded unified RAM image: %0s", ram_file);
    end
    rc = $value$plusargs("max_cycles=%d", max_cycles);
    rc = $value$plusargs("ram_lat=%d", ram_lat);
    if (ram_lat < 1) ram_lat = 1;

    repeat (5) @(posedge clk);
    rst = 1'b0;
    $display("[tb_linux_soc] reset released, PC=0x%08x (BootROM), ram_lat=%0d, max_cycles=%0d",
             `SOC_ROM_BASE, ram_lat, max_cycles);
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      ram_ack     <= 1'b0;
      ram_rdata   <= 32'd0;
      ram_err     <= 1'b0;
      ram_pend    <= 1'b0;
      ram_cnt     <= 0;
      ram_addr_q  <= 32'd0;
      ram_wdata_q <= 32'd0;
      ram_wstrb_q <= 4'b0000;
      ram_we_q    <= 1'b0;
    end
    else begin
      ram_ack <= 1'b0;
      ram_err <= 1'b0;

      if (!ram_pend) begin
        if (ram_req && !ram_ack) begin
          if (ram_lat == 1) begin
            ram_ack <= 1'b1;
            if (ram_off >= (RAM_WORDS * 4)) begin
              ram_err   <= 1'b1;
              ram_rdata <= 32'd0;
            end
            else if (ram_we) begin
              if (ram_wstrb[0]) ram_mem[ram_off[17:2]][ 7: 0] <= ram_wdata[ 7: 0];
              if (ram_wstrb[1]) ram_mem[ram_off[17:2]][15: 8] <= ram_wdata[15: 8];
              if (ram_wstrb[2]) ram_mem[ram_off[17:2]][23:16] <= ram_wdata[23:16];
              if (ram_wstrb[3]) ram_mem[ram_off[17:2]][31:24] <= ram_wdata[31:24];
              ram_rdata <= 32'd0;
            end
            else begin
              ram_rdata <= ram_mem[ram_off[17:2]];
            end
          end
          else begin
            ram_pend    <= 1'b1;
            ram_cnt     <= ram_lat - 1;
            ram_addr_q  <= ram_addr;
            ram_wdata_q <= ram_wdata;
            ram_wstrb_q <= ram_wstrb;
            ram_we_q    <= ram_we;
          end
        end
      end
      else begin
        if (ram_cnt == 1) begin
          ram_pend <= 1'b0;
          ram_ack  <= 1'b1;
          if (ram_off_q >= (RAM_WORDS * 4)) begin
            ram_err   <= 1'b1;
            ram_rdata <= 32'd0;
          end
          else if (ram_we_q) begin
            if (ram_wstrb_q[0]) ram_mem[ram_off_q[17:2]][ 7: 0] <= ram_wdata_q[ 7: 0];
            if (ram_wstrb_q[1]) ram_mem[ram_off_q[17:2]][15: 8] <= ram_wdata_q[15: 8];
            if (ram_wstrb_q[2]) ram_mem[ram_off_q[17:2]][23:16] <= ram_wdata_q[23:16];
            if (ram_wstrb_q[3]) ram_mem[ram_off_q[17:2]][31:24] <= ram_wdata_q[31:24];
            ram_rdata <= 32'd0;
          end
          else begin
            ram_rdata <= ram_mem[ram_off_q[17:2]];
          end
        end
        else begin
          ram_cnt <= ram_cnt - 1;
        end
      end
    end
  end

  // ---- 串口控制台实时打印 (观测 NS16550A 输出) ----
  always @(posedge clk) begin
    if (!rst && uart_tx_pulse) begin
      $write("%c", uart_tx_byte);
    end
  end

  // ---- 监视 tohost / 非法指令 / 超时 ----
  wire [31:0] tohost_word = ram_mem[TOHOST_IDX];

  always @(posedge clk) begin
    if (!rst) begin
      cycles <= cycles + 32'd1;

      if (cycles > max_cycles) begin
        $display("\n[tb_linux_soc] FAIL: timeout (%0d cycles), pc=0x%08x id_pc=0x%08x instr=0x%08x",
                 max_cycles, dbg_pc, dbg_id_pc, dbg_instr);
        $display("  RESULT : FAIL");
        $finish;
      end

      if (dbg_illegal) begin
        $display("\n[tb_linux_soc] FAIL: unhandled illegal instruction id_pc=0x%08x instr=0x%08x",
                 dbg_id_pc, dbg_instr);
        $display("  RESULT : FAIL");
        $finish;
      end

      if (tohost_word == 32'd1) begin
        $display("\n=================================================");
        $display("  rv32_soc Unified Memory + VIPT Cache + CLINT/PLIC/16550 PASS");
        $display("  cycles = %0d", cycles);
        $display("  RESULT : PASS");
        $finish;
      end
      else if (tohost_word != 32'd0) begin
        $display("\n[tb_linux_soc] FAIL: test failed with tohost=0x%08x (code %0d), cycles=%0d",
                 tohost_word, tohost_word, cycles);
        $display("  RESULT : FAIL");
        $finish;
      end
    end
  end

endmodule
