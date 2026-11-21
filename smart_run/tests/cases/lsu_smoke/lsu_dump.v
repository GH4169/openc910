`timescale 1ns/100ps

`define LSU_SMOKE_CPU tb.x_soc.x_cpu_sub_system_axi.x_rv_integration_platform.x_cpu_top
`define LSU_SMOKE_CORE `LSU_SMOKE_CPU.x_ct_top_0.x_ct_core

module lsu_dump;
  reg [39:0] pass_pc;
  reg [39:0] fail_pc;
  integer report_file;

  initial begin
    if (!$value$plusargs("pass_pc=%h", pass_pc) ||
        !$value$plusargs("fail_pc=%h", fail_pc)) begin
      $fatal(1, "Provide +pass_pc and +fail_pc from lsu_smoke.elf");
    end
    $dumpfile("lsu.fst");
    $dumpvars(1, tb.clk, tb.rst_b,
      `LSU_SMOKE_CPU.core0_pad_retire0, `LSU_SMOKE_CPU.core0_pad_retire0_pc,
      `LSU_SMOKE_CPU.core0_pad_retire1, `LSU_SMOKE_CPU.core0_pad_retire1_pc,
      `LSU_SMOKE_CPU.core0_pad_retire2, `LSU_SMOKE_CPU.core0_pad_retire2_pc);
    $dumpvars(0, `LSU_SMOKE_CORE.x_ct_lsu_top);
  end

  function automatic core0_retired(input [39:0] pc);
    core0_retired =
      (`LSU_SMOKE_CPU.core0_pad_retire0 && `LSU_SMOKE_CPU.core0_pad_retire0_pc == pc) ||
      (`LSU_SMOKE_CPU.core0_pad_retire1 && `LSU_SMOKE_CPU.core0_pad_retire1_pc == pc) ||
      (`LSU_SMOKE_CPU.core0_pad_retire2 && `LSU_SMOKE_CPU.core0_pad_retire2_pc == pc);
  endfunction

  always @(negedge tb.clk) begin
    if (tb.rst_b && core0_retired(fail_pc)) begin
      $fatal(1, "Core 0 retired failure PC 0x%h", fail_pc);
    end
    if (tb.rst_b && core0_retired(pass_pc)) begin
      report_file = $fopen("run_case.report", "w");
      $fwrite(report_file, "TEST PASS\n");
      $fclose(report_file);
      $display("TEST PASS: Core 0 retired success PC 0x%h", pass_pc);
      $finish;
    end
  end

  initial begin
    #50000;
    $fatal(1, "LSU smoke timed out at 50 us");
  end
endmodule

`undef LSU_SMOKE_CORE
`undef LSU_SMOKE_CPU
