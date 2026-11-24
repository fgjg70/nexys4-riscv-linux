`timescale 1ns/1ps
`include "rv32_defs.vh"

// ============================================================================
// tb_core.v — 五级流水线系统级自校验测试平台 (纯 Verilog-2001)
// ----------------------------------------------------------------------------
// 机制:
//   - 通过 +imem=<hex> 装入指令存储器, +max_cycles=<N> 覆盖超时上限;
//   - 监视 DMEM 的 tohost 地址 (DMEM_BASE + 0x2000):
//       1   -> PASS
//       N+1 -> 测试 N FAIL
//       0   -> 运行中
//   - 监视 core 的 dbg_illegal 粘滞标志, 任何非法指令判失败。
// ============================================================================

module tb_core;
  localparam TCLK_HALF = 5;    // 100 MHz 等效 (ns)

  localparam [31:0] TOHOST_ADDR     = `DMEM_BASE + 32'h2000;
  localparam        TOHOST_WORD_IDX = (TOHOST_ADDR - `DMEM_BASE) / 4;

  reg        clk;
  reg        rst;
  reg [31:0] max_cycles;
  reg [31:0] cycles;
  reg        finished;

  initial begin
    clk        = 1'b0;
    rst        = 1'b1;
    max_cycles = 32'd20000;
    cycles     = 32'd0;
    finished   = 1'b0;
  end

  always #(TCLK_HALF) clk = ~clk;

  wire [31:0] dbg_pc, dbg_id_pc, dbg_instr, dbg_rdata;
  wire        dbg_illegal;
  wire [31:0] dbg_mem_addr, dbg_mem_wdata;
  wire        dbg_mem_we, ext_we, ext_re;
  wire [31:0] ext_addr, ext_wdata, ext_rdata;
  wire [3:0]  ext_wstrb;

  core u_dut (
    .clk           (clk),
    .rst           (rst),
    .dbg_pc        (dbg_pc),
    .dbg_id_pc     (dbg_id_pc),
    .dbg_instr     (dbg_instr),
    .dbg_illegal   (dbg_illegal),
    .dbg_raddr     (5'd0),
    .dbg_rdata     (dbg_rdata),
    .dbg_mem_we    (dbg_mem_we),
    .dbg_mem_addr  (dbg_mem_addr),
    .dbg_mem_wdata (dbg_mem_wdata),
    .dbg_stall     (),
    .dbg_redirect  (),
    .ext_we        (ext_we),
    .ext_re        (ext_re),
    .ext_addr      (ext_addr),
    .ext_wdata     (ext_wdata),
    .ext_wstrb     (ext_wstrb),
    .ext_rdata     (ext_rdata),
    .irq_timer     (1'b0)
  );

  assign ext_rdata = 32'h0;

  wire [31:0] tohost_word = u_dut.u_dmem.mem[TOHOST_WORD_IDX];

`ifndef SYNTHESIS
  always @(negedge clk) begin
    if (!rst && $test$plusargs("illegal_trace") && cycles >= 32'd40) begin
      $display("[pre] cyc=%0d if_pc=0x%08x if_instr=0x%08x | ex_pc=0x%08x ex_illegal=%b",
               cycles, u_dut.if_pc, u_dut.if_instr, u_dut.id_ex_pc, u_dut.id_ex_ctrl[`CTRL_ILLEGAL]);
      $display("      id_illegal=%b exc_req=%b trap_req=%b trap_enter=%b trap_redir=%b irq_take=%b irq_pend=%b",
               u_dut.id_ctrl[`CTRL_ILLEGAL], u_dut.exc_req, u_dut.trap_req, u_dut.trap_enter,
               u_dut.trap_redir, u_dut.irq_take, u_dut.irq_pending);
      $display("      pipe_stall=%b redirect=%b redirect_raw=%b actual_taken=%b pred_ok=%b ex_taken=%b pc_src=%b",
               u_dut.pipe_stall, u_dut.redirect, u_dut.redirect_raw, u_dut.actual_taken,
               u_dut.pred_ok, u_dut.ex_taken, u_dut.pc_src);
      $display("      dmem_we=%b mem_read=%b mem_write=%b reg_write=%b pc_sel=%0d dbg_illegal=%b",
               u_dut.dmem_we, u_dut.id_ex_ctrl[`CTRL_MEM_READ], u_dut.id_ex_ctrl[`CTRL_MEM_WRITE],
               u_dut.id_ex_ctrl[`CTRL_REG_WRITE], u_dut.id_ex_ctrl[`CTRL_PC_SEL], dbg_illegal);
    end
  end

  initial begin : trace_proc
    if ($test$plusargs("illegal_trace")) begin
      $display("[trace] cycle | if_pc      if_instr    (ID) | ex_pc      | ill stll bubl trap_enter redirect exc_req");
      forever begin
        @(posedge clk);
        if (!rst) begin
          $display("[trace] %5d | 0x%08x 0x%08x | 0x%08x |  %b   %b    %b      %b        %b      %b",
                   cycles,
                   u_dut.if_pc, u_dut.if_instr,
                   u_dut.id_ex_pc,
                   u_dut.id_ctrl[`CTRL_ILLEGAL], u_dut.pipe_stall, u_dut.id_ex_bubble,
                   u_dut.trap_enter, u_dut.redirect, u_dut.exc_req);
        end
      end
    end
  end
`endif

  reg [8*256-1:0] dump_file;
  initial begin
    if ($value$plusargs("dump=%s", dump_file)) begin
      $dumpfile(dump_file);
      $dumpvars(0, tb_core);
    end
    if (!$value$plusargs("max_cycles=%d", max_cycles))
      max_cycles = 32'd20000;
    repeat (4) @(posedge clk);
    rst = 1'b0;
    $display("[tb_core] 复位释放, PC=0x%08x, max_cycles=%0d", `PC_RESET, max_cycles);
  end

  always @(posedge clk) begin
    if (!rst && !finished) begin
      cycles <= cycles + 32'd1;

      if (cycles > max_cycles) begin
        finished = 1'b1;
        $display("[tb_core] FAIL: 超时 (%0d 周期), 最后 PC=0x%08x instr=0x%08x",
                 max_cycles, dbg_pc, dbg_instr);
        $display("  RESULT : FAIL");
        $finish;
      end

      if (dbg_illegal) begin
        finished = 1'b1;
        $display("[tb_core] FAIL: 遇到非法指令 (id_pc=0x%08x instr=0x%08x)",
                 dbg_id_pc, dbg_instr);
        $display("  RESULT : FAIL");
        $finish;
      end

      if (tohost_word == 32'd1) begin
        finished = 1'b1;
        $display("=================================================");
        $display("  全部 6 组测试通过 (算术/冒险/访存/非对齐/分支/移位)");
        $display("  执行周期: %0d", cycles);
        $display("  RESULT : PASS");
        $finish;
      end else if (tohost_word != 32'd0) begin
        finished = 1'b1;
        $display("[tb_core] FAIL: 测试 %0d 失败 (tohost=%0d)",
                 tohost_word - 32'd1, tohost_word);
        $display("[tb_core] 退出时 PC=0x%08x, 周期数 %0d", dbg_pc, cycles);
        $display("  RESULT : FAIL");
        $finish;
      end
    end
  end

endmodule
