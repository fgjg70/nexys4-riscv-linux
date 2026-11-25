`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// tb_soc.v — SoC 级测试平台 (core + mmio_subsys, 纯 Verilog-2001)
// ----------------------------------------------------------------------------
// UART TX 环回到 RX，同时验证 GPIO、定时器中断与 UART 收发通路。
// ============================================================================

module tb_soc;
  localparam TCLK_HALF = 10;          // 50 MHz (ns)
  localparam BIT_TIME  = 8680;        // 1/115200 s (ns)

  localparam [31:0] TOHOST_ADDR     = `DMEM_BASE + 32'h2000;
  localparam        TOHOST_WORD_IDX = (TOHOST_ADDR - `DMEM_BASE) / 4;
  localparam        RB_IDX          = (32'h90001010 - `DMEM_BASE) / 4;

  reg        clk;
  reg        rst;
  reg [31:0] max_cycles;
  reg [31:0] cycles;
  reg        finished;
  reg        pass_seen;

  initial begin
    clk        = 1'b0;
    rst        = 1'b1;
    max_cycles = 32'd400000;
    cycles     = 32'd0;
    finished   = 1'b0;
    pass_seen  = 1'b0;
  end

  always #(TCLK_HALF) clk = ~clk;

  wire [31:0] dbg_pc, dbg_id_pc, dbg_instr, dbg_rdata, dbg_mem_addr, dbg_mem_wdata;
  wire        dbg_illegal, dbg_mem_we;
  wire        ext_we, ext_re, uart_txd, uart_rxd;
  wire [31:0] ext_addr, ext_wdata, ext_rdata;
  wire [3:0]  ext_wstrb;
  wire [31:0] gpio_out, tx_bytes, rx_bytes;
  wire        irq_timer;

  core u_dut (
    .clk (clk), .rst (rst),
    .dbg_pc (dbg_pc), .dbg_id_pc (dbg_id_pc), .dbg_instr (dbg_instr), .dbg_illegal (dbg_illegal),
    .dbg_raddr (5'd0), .dbg_rdata (dbg_rdata),
    .dbg_mem_we (dbg_mem_we), .dbg_mem_addr (dbg_mem_addr), .dbg_mem_wdata (dbg_mem_wdata),
    .dbg_stall (), .dbg_redirect (),
    .ext_we (ext_we), .ext_re (ext_re), .ext_addr (ext_addr), .ext_wdata (ext_wdata),
    .ext_wstrb (ext_wstrb), .ext_rdata (ext_rdata),
    .irq_timer (irq_timer)
  );

  mmio_subsys #(.CLK_HZ(50_000_000), .BAUD_HZ(115_200)) u_mmio (
    .clk (clk), .rst (rst),
    .we (ext_we), .re (ext_re), .addr (ext_addr), .wdata (ext_wdata), .wstrb (ext_wstrb),
    .rdata (ext_rdata),
    .gpio_out (gpio_out), .gpio_in (32'hDEADBEEF),
    .uart_txd (uart_txd), .uart_rxd (uart_rxd),
    .tx_byte_count (tx_bytes), .rx_byte_count (rx_bytes),
    .irq_timer (irq_timer)
  );

  assign uart_rxd = uart_txd;      // 环回: 发送直接进接收

`ifndef SYNTHESIS
  initial begin
    if ($test$plusargs("pc_trace")) begin
      $display("[pctrace] cycle -> dbg_id_pc / instr");
      forever begin
        @(negedge clk);
        if (!rst) begin
          $display("[pctrace] %6d 0x%08x 0x%08x  s3=%0d s4=%0d",
                   cycles, dbg_id_pc, dbg_instr,
                   u_dut.u_cpu.u_regfile.mem[18], u_dut.u_cpu.u_regfile.mem[19]);
        end
      end
    end
  end

  initial begin
    if ($test$plusargs("trap_csr_trace")) begin
      $display("[csrtrace] cycle | mcause      mepc        mtvec       mstatus | trap_req trap_cause irq_cause");
      forever begin
        @(negedge clk);
        if (!rst) begin
          $display("[csrtrace] %6d | 0x%08x 0x%08x 0x%08x 0x%08x |    %b     0x%02x     0x%02x",
                   cycles, u_dut.u_cpu.u_csr.mcause, u_dut.u_cpu.u_csr.mepc, u_dut.u_cpu.u_csr.mtvec,
                   {19'b0, u_dut.u_cpu.u_csr.st_mpp, 3'b0, u_dut.u_cpu.u_csr.st_mpie, 3'b0,
                    u_dut.u_cpu.u_csr.st_mie, 3'b0},
                   u_dut.u_cpu.trap_req, u_dut.u_cpu.trap_cause, u_dut.u_cpu.irq_cause);
        end
      end
    end
  end

  initial begin
    if ($test$plusargs("irq_trace")) begin
      $display("[irqtrace]  cycle |     mtime      mtimecmp | MTIE MIE gt | irq_timer irq_pending");
      forever begin
        @(negedge clk);
        if (!rst) begin
          $display("[irqtrace] %6d | %10d %12d |  %b   %b   %b |     %b          %b",
                   cycles,
                   u_mmio.cycle_cnt[31:0], u_mmio.mtimecmp[31:0],
                   u_dut.u_cpu.u_csr.ie_mtie, u_dut.u_cpu.u_csr.st_mie,
                   (u_mmio.cycle_cnt >= u_mmio.mtimecmp),
                   irq_timer, u_dut.u_cpu.irq_pending);
          if (u_dut.u_cpu.irq_pending || u_dut.u_cpu.trap_enter || u_dut.u_cpu.irq_take)
            $display("           >> irq_take=%b trap_req=%b trap_enter=%b exc_req=%b stall=%b mret=%b | s2(x18)=%0d s3(x19)=%0d",
                     u_dut.u_cpu.irq_take, u_dut.u_cpu.trap_req, u_dut.u_cpu.trap_enter, u_dut.u_cpu.exc_req,
                     u_dut.u_cpu.pipe_stall, u_dut.u_cpu.mret_taken,
                     u_dut.u_cpu.u_regfile.mem[18], u_dut.u_cpu.u_regfile.mem[19]);
        end
      end
    end
  end
`endif

  wire [31:0] tohost_word = u_dut.u_dmem.mem[TOHOST_WORD_IDX];
  wire [31:0] rb0 = u_dut.u_dmem.mem[RB_IDX + 0];
  wire [31:0] rb1 = u_dut.u_dmem.mem[RB_IDX + 1];
  wire [31:0] rb2 = u_dut.u_dmem.mem[RB_IDX + 2];

  // ---- UART 监控: 解码 uart_txd 上的字节 ----
  reg  [7:0] rx_sh;
  integer    uart_recv;
  reg        uart_ok;
  integer    bit_i;

  initial begin : uart_monitor
    uart_recv = 0;
    uart_ok   = 1'b1;
    forever begin
      @(negedge uart_txd);
      #(BIT_TIME / 2);
      if (uart_txd === 1'b0) begin
        for (bit_i = 0; bit_i < 8; bit_i = bit_i + 1) begin
          #(BIT_TIME);
          rx_sh[bit_i] = uart_txd;
        end
        #(BIT_TIME);
        uart_recv = uart_recv + 1;
        $display("[tb_soc] UART byte #%0d = 0x%02x", uart_recv, rx_sh);
        if (uart_recv == 1 && rx_sh !== 8'h4F) uart_ok = 1'b0;   // 'O'
        if (uart_recv == 2 && rx_sh !== 8'h4B) uart_ok = 1'b0;   // 'K'
        if (uart_recv == 3 && rx_sh !== 8'h0A) uart_ok = 1'b0;   // LF
      end
    end
  end

  initial begin
    if (!$value$plusargs("max_cycles=%d", max_cycles))
      max_cycles = 32'd400000;
    repeat (4) @(posedge clk);
    rst = 1'b0;
    $display("[tb_soc] reset released, PC=0x%08x, max_cycles=%0d", `PC_RESET, max_cycles);
  end

  // ---- 主循环 ----
  always @(posedge clk) begin
    if (!rst && !finished) begin
      cycles <= cycles + 32'd1;

      if (cycles > max_cycles) begin
        finished = 1'b1;
        $display("[tb_soc] FAIL: timeout (%0d cycles), PC=0x%08x instr=0x%08x",
                 max_cycles, dbg_pc, dbg_instr);
        $display("  RESULT : FAIL");
        $finish;
      end

      if (dbg_illegal) begin
        finished = 1'b1;
        $display("[tb_soc] FAIL: illegal instruction id_pc=0x%08x instr=0x%08x (fetch_pc=0x%08x)",
                 dbg_id_pc, dbg_instr, dbg_pc);
        $display("  RESULT : FAIL");
        $finish;
      end

      if (tohost_word == 32'd1) begin
        finished  = 1'b1;
        pass_seen = 1'b1;
      end else if (tohost_word != 32'd0) begin
        finished = 1'b1;
        $display("[tb_soc] FAIL: test group %0d failed (tohost=%0d), PC=0x%08x",
                 tohost_word - 32'd1, tohost_word, dbg_pc);
        $display("  RESULT : FAIL");
        $finish;
      end
    end
  end

  // ---- 内部 RX 探针 ----
  always @(posedge clk) begin
    if (!rst && u_mmio.rx_done)
      $display("[tb_soc] internal RX completed byte 0x%02x at %0t", u_mmio.rx_sh, $time);
  end

  // ---- MMIO 读探针 ----
  always @(posedge clk) begin
    if (!rst && u_mmio.sel_uart_rx)
      $display("[tb_soc] CPU reads MMIO_UART_RX -> rdata=0x%08x (rx_byte=0x%02x rdy=%b)",
               ext_rdata, u_mmio.rx_byte, u_mmio.rx_rdy);
  end

  // ---- 时间级看门狗 (50 ms = 50,000,000 ns) ----
  initial begin : watchdog
    #(50_000_000);
    $display("[tb_soc] FAIL: global timeout at %0t, PC=0x%08x tohost=0x%08x uart_recv=%0d",
             $time, dbg_pc, tohost_word, uart_recv);
    $display("  RESULT : FAIL");
    $finish;
  end

  // ---- 收尾判定 ----
  initial begin : finish_check
    wait (pass_seen);
    wait (uart_recv >= 3);
    #(BIT_TIME * 2);
    $display("=================================================");
    $display("  gpio_out      = 0x%08x  (expect 0x5a5a5a5a)", gpio_out);
    $display("  UART readback = 0x%02x 0x%02x 0x%02x  (expect 4f 4b 0a)",
             rb0[7:0], rb1[7:0], rb2[7:0]);
    $display("  UART loopback = %0d bytes, sequence ok = %0d", uart_recv, uart_ok);
    $display("  TX/RX counters= %0d / %0d", tx_bytes, rx_bytes);
    $display("  cycles        = %0d", cycles);
    if (gpio_out !== 32'h5A5A5A5A) begin
      $display("  RESULT : FAIL (gpio_out mismatch)");
      $finish;
    end
    if (!uart_ok || uart_recv < 3) begin
      $display("  RESULT : FAIL (UART wire loopback mismatch)");
      $finish;
    end
    if (rb0[7:0] !== 8'h4F || rb1[7:0] !== 8'h4B || rb2[7:0] !== 8'h0A) begin
      $display("  RESULT : FAIL (CPU-side UART readback mismatch)");
      $finish;
    end
    $display("  RESULT : PASS");
    $finish;
  end

endmodule
