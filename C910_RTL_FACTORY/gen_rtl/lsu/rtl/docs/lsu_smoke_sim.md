# 用 Icarus Verilog 复现 C910 LSU 仿真

这次用仓库的 `smart_run` SoC 测试台运行了一段 RV64 裸机汇编。Core 0 从 PC `0x0` 取指，完成四次 load 读回校验后退休到成功地址 `0x128`。本次仿真在 35.620 µs 结束，日志为 `TEST PASS`。[仿真日志](../../../../../smart_run/work/lsu-smoke/simulation.log)

## RTL 有几个核，GTKWave 为什么只显示一个

| 层次 | 本次配置 |
| --- | --- |
| RTL 例化 | `openC910` 例化了两个 `ct_top`，实例名为 `x_ct_top_0` 和 `x_ct_top_1`。 |
| 测试台复位 | `smart_run` 把 Core 0 的 `pad_core0_rst_b` 接到系统复位，复位释放后从 `pad_core0_rvba = 0` 启动。Core 1 的低有效复位 `pad_core1_rst_b` 接 `1'b0`，用例全程保持复位。 |
| FST 导出 | Icarus 编译了整个 SoC 层次。编译选项 `-DNO_DUMP` 关闭原测试台的全局 dump，辅助顶层 `lsu_dump` 递归记录 `x_ct_top_0.x_ct_core.x_ct_lsu_top`。此外只显式记录 `tb.clk`、`tb.rst_b` 和 Core 0 的三路退休有效位及 PC。 |

[双核配置](../../../cpu/rtl/cpu_cfig.h#L238) · [Core 0 实例](../../../cpu/rtl/openC910.v#L723) · [Core 1 实例](../../../cpu/rtl/openC910.v#L865) · [Core 0 复位与入口](../../../../../smart_run/logical/common/cpu_sub_system_axi.v#L221) · [Core 1 复位](../../../../../smart_run/logical/common/cpu_sub_system_axi.v#L327) · [导出代码](../../../../../smart_run/tests/cases/lsu_smoke/lsu_dump.v#L16)

GTKWave 左上角的 SST 从 FST 中的实例和信号生成。截图里的 `tb → x_soc → … → x_ct_top_0 → x_ct_core → x_ct_lsu_top` 是已记录信号的层次路径。RTL 中，IFU、IDU、IU、VFPU、CP0 和 RTU 都与 LSU 同挂在 `x_ct_core` 下。MMU、PMP 和 BIU 与 `x_ct_core` 同挂在每个核的 `ct_top` 下。[ct_core.v](../../../cpu/rtl/ct_core.v#L2480) · [ct_top.v](../../../cpu/rtl/ct_top.v#L849)

点 `x_ct_lsu_top` 左边的三角形，可展开 `x_ct_lsu_ld_ag`、`x_ct_lsu_ld_dc`、`x_ct_lsu_ld_da`、`x_ct_lsu_ld_wb`、`x_ct_lsu_sq`、`x_ct_lsu_rb`、`x_ct_lsu_lfb`、`x_ct_lsu_wmb` 等子模块。点实例后，在左下角选信号，再点 **Append** 加到中间信号列表。[LSU 实例列表](../ct_lsu_top.v#L2801)

## 测试激励和访存指令

链接时把 `.text` 放到 `0x0`，把按 64 B 对齐的 `.data` 放到 `0x40000`。测试台在仿真开始时把 `inst.pat` 和 `data.pat` 装入 SRAM。地址 `0x40000` 的初值是 `0x0123456789abcdef`，地址 `0x40008` 的初值是 `0xfedcba9876543210`。两者在同一条 64 B D-cache line 内，所有读写均为自然对齐的 8 B 访问。[SRAM 加载](../../../../../smart_run/logical/tb/tb.v#L134) · [D-cache tag 索引](../ct_lsu_ld_ag.v#L1138)

启动代码用 `csrw mtvec` 设置异常入口，用 `csrs` 写 T-Head CSR `MCOR (0x7c2)` 发起缓存和预测器无效化，再写 `MHCR (0x7c1)` 使能 I-cache、D-cache 和写分配。其余指令包括 `auipc`、`lui`、`addi`、`addiw`、`slli`、`add`、`xor`、条件分支和跳转，用于装入地址及常量、生成依赖和校验数据。冷读后对结果做 `xor`，再串接 24 条加一和一条减 24，使第二次 load 的地址依赖冷读结果，并给回填留出时间。[CSR 的位定义](../../../cp0/rtl/ct_cp0_regs.v#L2825) · [本次反汇编](../../../../../smart_run/work/lsu-smoke/lsu_smoke.dis)

| PC | 指令 | 数据地址 | 激励及校验 |
| --- | --- | --- | --- |
| `0x088` | `ld t3, 0(s0)` | `0x40000` | 冷读，校验 `0x0123456789abcdef`。 |
| `0x094` | `fence rw, rw` | — | 第一处访存顺序屏障。 |
| `0x100` | `ld t4, 8(s1)` | `0x40008` | 读同一缓存行的第二个双字，校验 `0xfedcba9876543210`。 |
| `0x110` | `sd t2, 8(s1)` | `0x40008` | 写入 `0x13579bdf2468ace0`。 |
| `0x114` | `ld t5, 8(s1)` | `0x40008` | 紧跟 store 读同一地址，校验新值。 |
| `0x11c` | `fence rw, rw` | — | 第二处访存顺序屏障。 |
| `0x120` | `ld t6, 8(s0)` | `0x40008` | 屏障后的读回，仍应得到新值。 |

数据访存共 **4 条 `ld`、1 条 `sd`**。在 `Store | DA` 分组里用 `st_da_fence_inst` 和 `st_da_inst_vld` 一起观察两条 `fence`。A 右边紧随冷读出现的第一段 ST 流水活动对应 PC `0x094` 的 `fence`，实际写 `0x40008` 的 `sd` 在后面。[FENCE 标志](../ct_lsu_st_da.v#L1055)

任一读回校验失败就跳到 `lsu_test_fail`（本次 PC `0x130`），异常也跳到此处。成功时到 `lsu_test_pass`（本次 PC `0x128`）。`lsu_dump` 在测试台时钟下降沿检查同一核的三路退休槽，看到成功 PC 才写入 `TEST PASS`。先前试跑曾由原测试台的写回总线魔数提前结束，正式波形使用退休 PC 判定。到仿真时间 50 µs 仍未结束会触发超时。[原测试台的魔数检查](../../../../../smart_run/logical/tb/tb.v#L257) · [本用例的退休检查](../../../../../smart_run/tests/cases/lsu_smoke/lsu_dump.v#L24)

## 用 Make 逐步复现

从仓库根目录执行下面四条命令。当前机器的工具已就绪，测试源文件随仓库提供。

```bash
cd smart_run
make lsu-build
make lsu-compile
make lsu-run
make lsu-wave
```

| 命令 | 这一阶段做什么 |
| --- | --- |
| `make lsu-build` | 汇编并链接裸机程序，生成 `lsu_smoke.dis`、`inst.pat` 和 `data.pat`。 |
| `make lsu-compile` | 用 Icarus 编译整个 C910 SoC 测试台和 `lsu_dump`，生成 `xuantie_core.vvp`。这里可以看 `compile.log`。 |
| `make lsu-run` | 运行 vvp，用退休 PC 判定结果。终端打印 `TEST PASS` 后，可查看 `simulation.log` 和 `lsu.fst`。可以单独重复此步。 |
| `make lsu-wave` | 在独立桌面打开新 FST，自动加载 LSU 信号分组和 A～E 标记。 |

本次复跑产物在 `smart_run/work/lsu-smoke-make/`，截图对应的原始波形在 `smart_run/work/lsu-smoke/`。编译与仿真串行，绑定到单个逻辑核，CPU 配额为该核的 80%，内存硬上限 2.5 GiB，交换空间上限 256 MiB。原始运行的编译内存峰值约 2.15 GiB，vvp 仿真用时约 233 秒。[Make 目标](../../../../../smart_run/setup/lsu_smoke.mk) · [每步命令](../../../../../smart_run/tests/cases/lsu_smoke/flow.sh) · [原编译日志](../../../../../smart_run/work/lsu-smoke/compile.log)

若在同类 WSL Ubuntu 环境首次配置，先安装仿真工具。工具可以来自 PATH 或当前机器使用的用户缓存目录。限资源运行依赖 systemd 用户服务和 cgroup v2。GTKWave 在本机通过 `codex-desktop` 启动，未安装该包装命令的机器直接从当前图形会话打开。

```bash
sudo apt install make iverilog binutils-riscv64-unknown-elf gtkwave xxd time util-linux
```

修改测试汇编后先运行 `make lsu-build` 再运行 `make lsu-run`。修改 RTL 或导出范围后先运行 `make lsu-compile` 再运行 `make lsu-run`。PC 和波形时间会随激励和工具版本变化，可从新反汇编和波形重新定位。[汇编激励](../../../../../smart_run/tests/cases/lsu_smoke/lsu_smoke.S) · [波形导出和退休检查](../../../../../smart_run/tests/cases/lsu_smoke/lsu_dump.v)

## 用 GTKWave 对照波形

`make lsu-wave` 会把逐级布局 `lsu-stage.gtkw` 复制到运行目录。中间信号栏默认显示总览和可折叠的 stage，双击分组名可展开。需要定位某一拍时，用 **Time → Move To Time** 跳到对应时间，例如 `34235 ns`。第三屏若是只读观看模式，可以在另一个终端执行 `codex-desktop control` 来操作 GTKWave。[逐级读图指南](lsu_wave_guide.md) · [GTKWave 布局](../../../../../smart_run/tests/cases/lsu_smoke/lsu-stage.gtkw) · [复跑波形](../../../../../smart_run/work/lsu-smoke-make/lsu.fst)

| 标记 | 时间 | 看哪些信号 |
| --- | ---: | --- |
| A | 34.235 µs | 冷读在 DA 有效，`ld_da_addr=0x40000`、`ld_da_dcache_hit=0`、`ld_da_rb_create_vld=1`。34.245 µs 可看到 LSU 向 BIU 发读请求。 |
| B | 34.705 µs | BIU 返回后，LFB 送 D-cache 回填，`lfb_dcache_arb_ld_req` 和 `lfb_dcache_arb_ld_tag_req` 为 1。冷读数据已在 34.675 µs 写回。 |
| C | 35.185 µs | 第二条 load 在 DA，地址为 `0x40008`，`ld_da_dcache_hit=1`。35.195 µs 写回原值 `0xfedcba9876543210`。 |
| D | 35.275 µs | `sd` 在 35.225 µs 创建 SQ 条目，35.235 µs 对应写数据有效。紧跟的 load 在 DA 看到 `x_ct_lsu_ld_da.ld_da_fwd_wmb_vld=1`，下一拍写回 `0x13579bdf2468ace0`。 |
| E | 35.595 µs | 屏障后的 load 写回同一个新值，`lsu_idu_wb_pipe3_wb_preg_vld=1`。35.615 µs 可在退休信号上看到成功 PC `0x128`。 |

追一条 load 时先看 `idu_lsu_rf_pipe3_sel → ld_ag_inst_vld → ld_dc_inst_vld → ld_da_inst_vld`，再按有效位读地址、IID、hit 和写回数据。同一 IID 可能因重发多次经过流水线。例如 PC `0x100` 的 load 在 35.075 µs 和 35.185 µs 都到过 DA，最终写回发生在 35.195 µs。追 store 时同时看地址的 pipe4 和数据的 pipe5，中间用 `st_dc_sq_create_vld` 标出 SQ 建项，之后看 `sq_wmb_pop_to_ce_req`。

### 扩大波形范围

在 `smart_run/tests/cases/lsu_smoke/lsu_dump.v` 的现有 LSU dump 调用旁添加这些行。深度 `1` 记录所选实例本层，深度 `0` 包含子层。修改后执行 `make lsu-compile`、`make lsu-run` 和 `make lsu-wave`，GTKWave 会按新 FST 显示实例树。

```verilog
$dumpvars(1, `LSU_SMOKE_CORE.x_ct_ifu_top,
             `LSU_SMOKE_CORE.x_ct_idu_top,
             `LSU_SMOKE_CORE.x_ct_rtu_top);
$dumpvars(1, `LSU_SMOKE_CPU.x_ct_top_0.x_ct_mmu_top);
$dumpvars(1, `LSU_SMOKE_CPU.x_ct_top_1);
```

加入 `x_ct_top_1` 会让 Core 1 出现在树上，信号仍对应保持复位的核。要让两个核执行指令，需要在测试台中给 Core 1 释放复位，再为两个 hart 安排各自的启动和数据地址。看跨核一致性时，测试还需要安排两个 hart 访问共享地址的顺序。

如果想一次查看 Core 0 的所有直接子模块，可以把原来的 LSU 递归调用替换成 ``$dumpvars(2, `LSU_SMOKE_CORE);``。这会记录 `x_ct_core` 和各直接子模块本层的信号。深挖 LSU 时用原来的递归调用或按需指定 LSU 子模块。导出的信号越多，FST 和仿真开销越大。
