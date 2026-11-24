`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// tb_sw.v — 通用裸机程序测试台 (core + mmio_subsys, 纯 Verilog-2001)
// ----------------------------------------------------------------------------
// 用途: 跑任意 C/汇编程序, 程序写 tohost=1 后把 dmem 日志缓冲区当字符串 dump 出来,
//       并输出完整流水线剖析统计、取指对齐自检与 BTB 复现判据自证。
// ============================================================================

module tb_sw;
  localparam TCLK_HALF = 10;          // 50 MHz (ns)

  localparam [31:0] TOHOST_ADDR = `DMEM_BASE + 32'h2000;
  localparam        TOHOST_IDX  = (TOHOST_ADDR - `DMEM_BASE) / 4;
  localparam [31:0] LOG_ADDR    = 32'h90003000;
  localparam        LOG_IDX     = (LOG_ADDR - `DMEM_BASE) / 4;
  localparam        LOG_MAX     = 4096;

  // BTB 几何常量 (纯 Verilog-2001 不允许在 localparam 中引用层次化参数,
  // 在 boot 时与 u_dut.u_btb.IDX_BITS / PC_TOP 显式断言一致, 且逐拍与 q_hit 自证)
  localparam BTB_IDX_BITS = 9;
  localparam BTB_PC_TOP   = 14;
  localparam BTB_TAG_LSB  = BTB_IDX_BITS + 2;
  localparam BTB_TAG_W    = BTB_PC_TOP - BTB_TAG_LSB;
  localparam BTB_N        = (1 << BTB_IDX_BITS);

  localparam [31:0] MMIO_MARK_A   = `MMIO_MARK;
  localparam [31:0] MMIO_RESULT_A = `MMIO_RESULT;

  reg        clk;
  reg        rst;
  reg [31:0] cycles;
  reg [31:0] max_cycles;
  reg        finished;
  reg        pass_seen;

  initial begin
    clk        = 1'b0;
    rst        = 1'b1;
    cycles     = 32'd0;
    max_cycles = 32'd2000000;
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

  assign uart_rxd = 1'b1;

  core u_dut (
    .clk (clk), .rst (rst),
    .dbg_pc (dbg_pc), .dbg_id_pc (dbg_id_pc), .dbg_instr (dbg_instr),
    .dbg_illegal (dbg_illegal),
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
    .gpio_out (gpio_out), .gpio_in (32'h0),
    .uart_txd (uart_txd), .uart_rxd (uart_rxd),
    .tx_byte_count (tx_bytes), .rx_byte_count (rx_bytes),
    .irq_timer (irq_timer)
  );

  wire [31:0] tohost_word = u_dut.u_dmem.mem[TOHOST_IDX];

  // ---- 测量窗口计数 (MMIO_MARK -> MMIO_RESULT) ----
  reg        in_window;
  reg [31:0] n_win_cycles;
  reg [31:0] n_win_fetch;
  reg [31:0] n_win_stall;
  reg [31:0] n_win_stall_lu;
  reg [31:0] n_win_lu_events;
  reg [31:0] n_win_lu_overlap;

  // ---- 语义断言参数 ----
  integer exp_lu_stall;
  integer exp_lu_events;
  integer exp_flush;
  integer exp_retire;
  integer lu_bubbles;
  integer dump_words;
  integer expect_hazards;
  integer expect_d2_cost;

  // ---- 上板跑分上报路径监视 ----
  reg        saw_mark, saw_result;
  reg [31:0] hw_result;
  always @(posedge clk) begin
    if (rst) begin
      saw_mark   <= 1'b0;
      saw_result <= 1'b0;
      hw_result  <= 32'd0;
      in_window  <= 1'b0;
    end else begin
      if (ext_we && (ext_addr == MMIO_MARK_A)) begin
        saw_mark  <= 1'b1;
        in_window <= 1'b1;
      end
      if (ext_we && (ext_addr == MMIO_RESULT_A)) begin
        saw_result <= 1'b1;
        hw_result  <= ext_wdata;
        in_window  <= 1'b0;
      end
    end
  end

  // ---- 启动 ----
  reg [8*256-1:0] dump_file;
  integer         rc;

  initial begin : boot
    in_window        = 1'b0;
    n_win_cycles     = 32'd0;
    n_win_fetch      = 32'd0;
    n_win_stall      = 32'd0;
    n_win_stall_lu   = 32'd0;
    n_win_lu_events  = 32'd0;
    n_win_lu_overlap = 32'd0;

    exp_lu_stall     = 0;
    exp_lu_events    = 0;
    exp_flush        = 0;
    exp_retire       = 0;
    lu_bubbles       = 0;
    dump_words       = 0;
    expect_hazards   = 1024;
    expect_d2_cost   = 0;

    if (BTB_IDX_BITS !== u_dut.u_btb.IDX_BITS || BTB_PC_TOP !== u_dut.u_btb.PC_TOP) begin
      $display("[tb_sw] FAIL: BTB 几何常量与 u_dut.u_btb 实例参数不一致");
      $display("  RESULT : FAIL");
      $finish;
    end

    if ($value$plusargs("dump=%s", dump_file)) begin
      $dumpfile(dump_file);
      $dumpvars(0, tb_sw);
    end
    if (!$value$plusargs("max_cycles=%d", max_cycles))
      max_cycles = 32'd2000000;
    rc = $value$plusargs("expect_lu_stall=%d",  exp_lu_stall);
    rc = $value$plusargs("expect_lu_events=%d", exp_lu_events);
    rc = $value$plusargs("expect_flush=%d",     exp_flush);
    rc = $value$plusargs("expect_retire=%d",    exp_retire);
    rc = $value$plusargs("lu_bubbles=%d",       lu_bubbles);
    rc = $value$plusargs("dump_words=%d",       dump_words);
    rc = $value$plusargs("expect_hazards=%d",   expect_hazards);
    rc = $value$plusargs("expect_d2_cost=%d",   expect_d2_cost);

    if (exp_lu_stall || exp_lu_events || exp_flush || exp_retire || lu_bubbles)
      $display("[tb_sw] 语义断言已开启: lu_stall=%0d lu_events=%0d flush=%0d retire=%0d bubbles=%0d",
               exp_lu_stall, exp_lu_events, exp_flush, exp_retire, lu_bubbles);
    repeat (4) @(posedge clk);
    rst = 1'b0;
    $display("[tb_sw] reset released, max_cycles=%0d", max_cycles);
  end

  // ---- 主循环 ----
  always @(posedge clk) begin
    if (!rst && !finished) begin
      cycles <= cycles + 32'd1;

      if (cycles > max_cycles) begin
        finished = 1'b1;
        $display("[tb_sw] FAIL: timeout (%0d cycles), id_pc=0x%08x instr=0x%08x",
                 max_cycles, dbg_id_pc, dbg_instr);
        $display("  RESULT : FAIL");
        $finish;
      end

      if (dbg_illegal) begin
        finished = 1'b1;
        $display("[tb_sw] FAIL: illegal instruction id_pc=0x%08x instr=0x%08x",
                 dbg_id_pc, dbg_instr);
        $display("  RESULT : FAIL");
        $finish;
      end

      if (tohost_word == 32'd1) begin
        finished  = 1'b1;
        pass_seen = 1'b1;
      end else if (tohost_word != 32'd0) begin
        finished = 1'b1;
        $display("[tb_sw] FAIL: tohost=0x%08x (not 1), id_pc=0x%08x",
                 tohost_word, dbg_id_pc);
        $display("  RESULT : FAIL");
        $finish;
      end
    end
  end

  // ---- 性能剖析计数器 ----
  reg [31:0] n_fetch, n_redirect, n_flush, n_stall, n_stall_lsu;
  reg [31:0] n_wb, n_wb_raw, n_both, n_hold_mem;
  reg [31:0] n_lu_events;
  reg        lu_d;
  reg [31:0] n_bcond, n_br_taken, n_jal, n_jalr;
  reg [31:0] n_stall_lu, n_stall_ls, n_stall_ex, n_load;
  reg [31:0] n_ctrl, n_mis;
  reg [31:0] n_mis_br, n_mis_jal, n_mis_jalr;
  reg [31:0] n_align_err;
  reg [31:0] n_ras_push, n_ras_pop, n_ras_nonempty;
  reg [31:0] n_pred_is_ret, n_ras_diff;
  reg [31:0] n_mis_br_nohit, n_mis_br_dir;
  reg [31:0] n_br_hit, n_br_nohit;
  reg        rep_hit_d;
  reg [31:0] n_btb_rep_bad;

  initial begin
    n_fetch        = 32'd0; n_redirect     = 32'd0; n_flush        = 32'd0;
    n_stall        = 32'd0; n_stall_lsu    = 32'd0;
    n_wb           = 32'd0; n_wb_raw       = 32'd0; n_both         = 32'd0;
    n_hold_mem     = 32'd0; n_lu_events    = 32'd0; lu_d           = 1'b0;
    n_bcond        = 32'd0; n_br_taken     = 32'd0; n_jal          = 32'd0;
    n_jalr         = 32'd0; n_stall_lu     = 32'd0; n_stall_ls     = 32'd0;
    n_stall_ex     = 32'd0; n_load         = 32'd0; n_ctrl         = 32'd0;
    n_mis          = 32'd0; n_mis_br       = 32'd0; n_mis_jal      = 32'd0;
    n_mis_jalr     = 32'd0; n_align_err    = 32'd0; n_ras_push     = 32'd0;
    n_ras_pop      = 32'd0; n_ras_nonempty = 32'd0; n_pred_is_ret  = 32'd0;
    n_ras_diff     = 32'd0; n_mis_br_nohit = 32'd0; n_mis_br_dir   = 32'd0;
    n_br_hit       = 32'd0; n_br_nohit     = 32'd0;
    rep_hit_d      = 1'b0;  n_btb_rep_bad  = 32'd0;
  end

  function btb_has_entry;
    input [31:0] pc_in;
    reg [BTB_IDX_BITS-1:0] idx;
    reg [BTB_TAG_W-1:0]    tg;
    begin
      idx = pc_in[BTB_IDX_BITS+1:2];
      tg  = pc_in[BTB_PC_TOP-1:BTB_TAG_LSB];
      btb_has_entry = u_dut.u_btb.vld[idx] && (u_dut.u_btb.tag[idx] == tg);
    end
  endfunction

  always @(posedge clk) begin
    if (!rst) begin
      if (rep_hit_d !== u_dut.pred_hit)
        n_btb_rep_bad = n_btb_rep_bad + 32'd1;
      rep_hit_d <= btb_has_entry(u_dut.pc_next);
    end
  end

  reg [31:0] exp_instr;
  always @(posedge clk) begin
    if (!rst) begin
      if (cycles > 32'd4 && !u_dut.if_id_flush && u_dut.if_pc != 32'd0) begin
        exp_instr = u_dut.u_imem.mem[u_dut.if_pc[13:2]];
        if (u_dut.if_instr !== exp_instr) begin
          n_align_err = n_align_err + 32'd1;
          if (n_align_err <= 32'd5)
            $display("[ALIGN] cycle %0d: if_pc=0x%08x if_instr=0x%08x 期望 0x%08x  <-- 取指错位!",
                     cycles, u_dut.if_pc, u_dut.if_instr, exp_instr);
        end
      end

      if (!u_dut.if_id_flush && !u_dut.pipe_stall) n_fetch     = n_fetch + 32'd1;
      if (u_dut.redirect)                          n_redirect  = n_redirect + 32'd1;
      if (u_dut.if_id_flush)                       n_flush     = n_flush + 32'd1;
      if (u_dut.pipe_stall)                        n_stall     = n_stall + 32'd1;
      if (u_dut.pipe_stall && u_dut.if_id_flush)   n_both      = n_both + 32'd1;
      if (u_dut.lsu_stall)                         n_stall_lsu = n_stall_lsu + 32'd1;

      if (u_dut.mem_wb_ctrl != `CTRL_NOP) begin
        n_wb_raw = n_wb_raw + 32'd1;
        if (!u_dut.u_hazard.hold_mem) n_wb = n_wb + 32'd1;
      end
      if (u_dut.u_hazard.hold_mem) n_hold_mem = n_hold_mem + 32'd1;

      if (in_window) begin
        n_win_cycles = n_win_cycles + 32'd1;
        if (!u_dut.if_id_flush && !u_dut.pipe_stall) n_win_fetch = n_win_fetch + 32'd1;
        if (u_dut.pipe_stall)                        n_win_stall = n_win_stall + 32'd1;
        if (u_dut.u_hazard.load_use)                 n_win_stall_lu = n_win_stall_lu + 32'd1;
        if (u_dut.u_hazard.load_use && !lu_d)        n_win_lu_events = n_win_lu_events + 32'd1;
        if (u_dut.u_hazard.load_use && (u_dut.lsu_stall || u_dut.md_busy))
          n_win_lu_overlap = n_win_lu_overlap + 32'd1;
      end

      if (u_dut.u_hazard.load_use)          n_stall_lu  = n_stall_lu + 32'd1;
      if (u_dut.u_hazard.load_use && !lu_d) n_lu_events = n_lu_events + 32'd1;
      lu_d <= u_dut.u_hazard.load_use;
      if (u_dut.lsu_stall)                  n_stall_ls  = n_stall_ls + 32'd1;
      if (u_dut.md_busy)                    n_stall_ex  = n_stall_ex + 32'd1;
      if (u_dut.ex_mem_ctrl[`CTRL_MEM_READ] && !u_dut.pipe_stall)
        n_load = n_load + 32'd1;

`ifdef RAS_EN
      if (u_dut.ex_is_call)   n_ras_push     = n_ras_push + 32'd1;
      if (u_dut.ex_is_ret)    n_ras_pop      = n_ras_pop + 32'd1;
      if (!u_dut.u_ras.empty) n_ras_nonempty = n_ras_nonempty + 32'd1;
      if (u_dut.pred_is_ret) begin
        n_pred_is_ret = n_pred_is_ret + 32'd1;
        if (u_dut.ras_top !== u_dut.btb_pred_target)
          n_ras_diff = n_ras_diff + 32'd1;
      end
`endif

      if (u_dut.id_ex_ctrl[`CTRL_PC_SEL] != `PC_NEXT && !u_dut.redir_kill) begin
        if (!u_dut.pipe_stall) n_ctrl = n_ctrl + 32'd1;
        if (u_dut.redirect_raw) n_mis = n_mis + 32'd1;
      end

      if (u_dut.redirect_raw && !u_dut.pipe_stall && !u_dut.redir_kill) begin
        if      (u_dut.id_ex_ctrl[`CTRL_PC_SEL] == `PC_BR) n_mis_br   = n_mis_br + 32'd1;
        else if (u_dut.id_ex_ctrl[`CTRL_PC_SEL] == `PC_J)  n_mis_jal  = n_mis_jal + 32'd1;
        else if (u_dut.id_ex_ctrl[`CTRL_PC_SEL] == `PC_JR) n_mis_jalr = n_mis_jalr + 32'd1;
      end

      if (u_dut.id_ex_ctrl[`CTRL_PC_SEL] == `PC_BR && !u_dut.redir_kill) begin
        if (btb_has_entry(u_dut.id_ex_pc)) n_br_hit   = n_br_hit + 32'd1;
        else                               n_br_nohit = n_br_nohit + 32'd1;
        if (u_dut.redirect_raw && !u_dut.pipe_stall) begin
          if (btb_has_entry(u_dut.id_ex_pc)) n_mis_br_dir   = n_mis_br_dir + 32'd1;
          else                               n_mis_br_nohit = n_mis_br_nohit + 32'd1;
        end
      end

      if (u_dut.id_ex_ctrl[`CTRL_PC_SEL] == `PC_BR && !u_dut.redir_kill) begin
        n_bcond = n_bcond + 32'd1;
        if (u_dut.redirect) n_br_taken = n_br_taken + 32'd1;
      end
      if (u_dut.redirect && !u_dut.redir_kill) begin
        if (u_dut.id_ex_ctrl[`CTRL_PC_SEL] == `PC_J)  n_jal  = n_jal + 32'd1;
        if (u_dut.id_ex_ctrl[`CTRL_PC_SEL] == `PC_JR) n_jalr = n_jalr + 32'd1;
      end
    end
  end

  // ---- PC 轨迹 (调试用, +trace 开启) ----
  reg trace_on;
  initial begin
    trace_on = 1'b0;
    if ($test$plusargs("trace")) trace_on = 1'b1;
  end

  always @(posedge clk) begin
    if (!rst && trace_on && cycles >= 32'd2140 && cycles < 32'd2200)
      $display("[trace] c=%0d pc=%08x pT=%b pTgt=%08x mis=%b stall=%b idpc=%08x sel=%0d aT=%b aTgt=%08x exT=%b",
               cycles, dbg_pc, u_dut.pred_taken, u_dut.pred_target,
               u_dut.redirect_raw, u_dut.pipe_stall,
               u_dut.id_ex_pc, u_dut.id_ex_ctrl[`CTRL_PC_SEL],
               u_dut.actual_taken, u_dut.actual_target, u_dut.ex_taken);
  end

  always @(posedge clk) begin
    if (!rst && trace_on && u_dut.wb_reg_write && (u_dut.wb_rd == 5'd5)
        && (u_dut.wb_data >= 32'h8000_03a0) && (u_dut.wb_data <= 32'h8000_03d0))
      $display("[x5] c=%0d  at_pc=0x%08x   x5 <- 0x%08x",
               cycles, u_dut.mem_wb_pc_plus4 - 32'd4, u_dut.wb_data);
  end

  // ---- 日志 dump 与收尾断言 ----
  integer    idx_i;
  integer    accounted, residual;
  integer    cycA, cycB, cycC, d1, d2;
  reg [7:0]  ch_b;
  reg        str_done;
`ifdef RAS_EN
  integer    bi;
  reg [31:0] n_ret_entries;
`endif

  initial begin : dump_log
    wait (pass_seen);
    #(TCLK_HALF * 4);
    $display("=================================================");
    $display("  cycles = %0d", cycles);
    $write("  --- program output ---\n");
    str_done = 1'b0;
    for (idx_i = 0; idx_i < LOG_MAX; idx_i = idx_i + 1) begin
      if (!str_done) begin
        ch_b = u_dut.u_dmem.mem[LOG_IDX + idx_i / 4] >> (8 * (idx_i % 4));
        if (ch_b == 8'h00)
          str_done = 1'b1;
        else
          $write("%c", ch_b);
      end
    end
    $display("  --- end of output ---");

    if (dump_words != 0) begin
      $display("  --- log words (微基准自量的原始数) ---");
      for (idx_i = 0; idx_i < dump_words; idx_i = idx_i + 1)
        $display("  log[%0d] = 0x%08x  (%0d)", idx_i,
                 u_dut.u_dmem.mem[LOG_IDX + idx_i], u_dut.u_dmem.mem[LOG_IDX + idx_i]);
    end

    $display("  --- profile ---");
    $display("  cycles     = %0d", cycles);
    $display("  fetch      = %0d   (IF/ID 前进的拍数 = 发射指令数)", n_fetch);
    $display("  retire(wb) = %0d   <- 真退休 (已排除 hold_mem 冻结拍)", n_wb);
    $display("  retire(raw)= %0d   <- 旧口径 (含冻结重复计数; 差 %0d = hold_mem 拍数 %0d)",
             n_wb_raw, n_wb_raw - n_wb, n_hold_mem);
    $display("  redirects  = %0d   实测冲刷拍数 = %0d  -> 每次 %0d.%02d 拍",
             n_redirect, n_flush,
             (n_redirect == 32'd0) ? 0 : n_flush / n_redirect,
             (n_redirect == 32'd0) ? 0 : ((n_flush * 100) / n_redirect) % 100);
    $display("  stalls     = %0d   (其中拆分访存 %0d) = %0d%%",
             n_stall, n_stall_lsu, (n_stall * 100) / ((cycles == 32'd0) ? 32'd1 : cycles));

    accounted = n_fetch + n_flush + n_stall - n_both;
    residual  = cycles - accounted;
    $display("  --- cycle accounting ---");
    $display("  cycles(%0d) = fetch(%0d) + flush(%0d) + stall(%0d) - both(%0d) + 残差(%0d)",
             cycles, n_fetch, n_flush, n_stall, n_both, residual);
    $display("  stall 构成和 = load-use(%0d) + split-mem(%0d) + muldiv(%0d) = %0d",
             n_stall_lu, n_stall_ls, n_stall_ex, n_stall_lu + n_stall_ls + n_stall_ex);
    $display("  互证: fetch - retire = %0d",
             (n_fetch >= n_wb) ? (n_fetch - n_wb) : -(n_wb - n_fetch));

    $display("  --- hardware score reporting ---");
    $display("  MMIO_MARK written   = %0d", saw_mark);
    $display("  MMIO_RESULT written = %0d   raw=0x%08x   CRC-valid=%0d   ticks=%0d",
             saw_result, hw_result, hw_result[31], hw_result[30:0]);

    $display("  --- measurement window ---");
    $display("  window cycles   = %0d   (软件自报 ticks = %0d)", n_win_cycles, hw_result[30:0]);
    $display("  window fetch    = %0d", n_win_fetch);
    $display("  window stalls   = %0d", n_win_stall);
    $display("  window load-use = %0d 拍 / %0d 冒险事件", n_win_stall_lu, n_win_lu_events);
    $display("  window lu overlap = %0d", n_win_lu_overlap);

    $display("  --- stall breakdown ---");
    $display("  load-use   = %0d  (%0d%%)   冒险事件 = %0d",
             n_stall_lu, (n_stall_lu * 100) / ((cycles == 32'd0) ? 32'd1 : cycles), n_lu_events);
    $display("  split-mem  = %0d", n_stall_ls);
    $display("  muldiv busy= %0d", n_stall_ex);
    $display("  load(MEM)  = %0d  (%0d%% of cycles)",
             n_load, (n_load * 100) / ((cycles == 32'd0) ? 32'd1 : cycles));

    $display("  --- 取指对齐自检 ---");
    if (n_align_err != 32'd0)
      $display("  *** 失败 %0d 次: if_pc 与 if_instr 不同源 (取指错位!) ***", n_align_err);
    else
      $display("  OK (0 次错位)");

`ifdef RAS_EN
    $display("  --- RAS (返回地址栈) ---");
    $display("  push(call) = %0d   pop(ret) = %0d   栈顶非空拍数 = %0d",
             n_ras_push, n_ras_pop, n_ras_nonempty);
    $display("  预测判为返回 = %0d   其中 RAS 目标 != BTB 目标 = %0d",
             n_pred_is_ret, n_ras_diff);
    n_ret_entries = 32'd0;
    for (bi = 0; bi < BTB_N; bi = bi + 1)
      if (u_dut.u_btb.vld[bi] && u_dut.u_btb.is_ret[bi])
        n_ret_entries = n_ret_entries + 32'd1;
    $display("  BTB 中 is_ret=1 的表项 = %0d", n_ret_entries);
`endif

    $display("  --- predictor accuracy ---");
    if (n_btb_rep_bad != 32'd0)
      $display("  *** 失败 %0d 次: btb_has_entry 与 btb 自身 q_hit 不一致 ***", n_btb_rep_bad);
    else
      $display("  BTB 复现判据自证: OK (0 次不一致; IDX=%0d TAG=%0d N=%0d)",
               BTB_IDX_BITS, BTB_TAG_W, BTB_N);
    $display("  ctrl-flow  = %0d   mispredict = %0d   accuracy = %0d%%",
             n_ctrl, n_mis, (n_ctrl == 32'd0) ? 0 : 100 - (n_mis * 100) / n_ctrl);
    $display("  cond branch = %0d  JAL = %0d  JALR = %0d", n_mis_br, n_mis_jal, n_mis_jalr);
    $display("  条件分支总数 = %0d   BTB 有表项 = %0d   无表项 = %0d",
             n_br_hit + n_br_nohit, n_br_hit, n_br_nohit);
    $display("  误判细分: 无表项 = %0d   有表项但方向错 = %0d", n_mis_br_nohit, n_mis_br_dir);
    $display("  cond branch total = %0d (taken %0d)  JAL = %0d  JALR = %0d",
             n_bcond, n_br_taken, n_jal, n_jalr);

    if (n_wb != 32'd0) begin
      $display("  CPI        = %0d.%03d", cycles / n_wb, ((cycles * 1000) / n_wb) % 1000);
      $display("  IPC        = %0d.%03d",
               (n_wb * 1000) / ((cycles == 32'd0) ? 32'd1 : cycles) / 1000,
               ((n_wb * 1000) / ((cycles == 32'd0) ? 32'd1 : cycles)) % 1000);
    end

    // ---- 语义断言 ----
    if (lu_bubbles != 0) begin
      cycA = u_dut.u_dmem.mem[LOG_IDX + 0];
      cycB = u_dut.u_dmem.mem[LOG_IDX + 1];
      cycC = u_dut.u_dmem.mem[LOG_IDX + 2];
      d1   = cycC - cycA;
      d2   = cycB - cycA;
      $display("  [断言] 微基准自量: cycA=%0d cycB=%0d cycC=%0d | 距离1=%0d 距离2=%0d",
               cycA, cycB, cycC, d1, d2);
      if (d1 != lu_bubbles * expect_hazards) begin
        $display("[tb_sw] FAIL: 距离1 load-use 代价 %0d != 期望 %0d", d1, lu_bubbles * expect_hazards);
        $display("  RESULT : FAIL");
        $finish;
      end
      if (d2 != expect_d2_cost) begin
        $display("[tb_sw] FAIL: 距离2 load-use 代价 %0d != 期望 %0d", d2, expect_d2_cost);
        $display("  RESULT : FAIL");
        $finish;
      end
      if (n_stall_lu != (lu_bubbles * expect_hazards + expect_d2_cost)) begin
        $display("[tb_sw] FAIL: TB 侧 load-use 停顿 %0d != 期望 %0d",
                 n_stall_lu, lu_bubbles * expect_hazards + expect_d2_cost);
        $display("  RESULT : FAIL");
        $finish;
      end
    end

    if (exp_lu_events != 0 && n_lu_events != exp_lu_events) begin
      $display("[tb_sw] FAIL: load-use 事件数 期望 %0d 实测 %0d", exp_lu_events, n_lu_events);
      $display("  RESULT : FAIL");
      $finish;
    end
    if (exp_lu_stall != 0 && n_stall_lu != exp_lu_stall) begin
      $display("[tb_sw] FAIL: load-use 停顿拍数 期望 %0d 实测 %0d", exp_lu_stall, n_stall_lu);
      $display("  RESULT : FAIL");
      $finish;
    end
    if (exp_flush != 0 && n_flush != exp_flush) begin
      $display("[tb_sw] FAIL: if_id_flush 拍数 期望 %0d 实测 %0d", exp_flush, n_flush);
      $display("  RESULT : FAIL");
      $finish;
    end
    if (exp_retire != 0 && n_wb != exp_retire) begin
      $display("[tb_sw] FAIL: 真退休指令数 期望 %0d 实测 %0d", exp_retire, n_wb);
      $display("  RESULT : FAIL");
      $finish;
    end
    if (n_align_err != 32'd0) begin
      $display("[tb_sw] FAIL: 取指错位 %0d 次 (if_pc 与 if_instr 不同源)", n_align_err);
      $display("  RESULT : FAIL");
      $finish;
    end
    if (n_btb_rep_bad != 32'd0) begin
      $display("[tb_sw] FAIL: btb_has_entry 与 btb 的 q_hit 不一致 %0d 次", n_btb_rep_bad);
      $display("  RESULT : FAIL");
      $finish;
    end

    $display("  RESULT : PASS");
    $finish;
  end

  // ---- 时间级看门狗 (500 ms = 500,000,000 ns) ----
  initial begin : watchdog
    #(500_000_000);
    $display("[tb_sw] FAIL: global timeout at %0t, tohost=0x%08x cycles=%0d",
             $time, tohost_word, cycles);
    $display("  RESULT : FAIL");
    $finish;
  end

endmodule
