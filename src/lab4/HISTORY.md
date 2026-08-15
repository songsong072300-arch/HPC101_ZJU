# Lab 4 CPU 优化历史

本文记录 AMSS-NCKU CPU 路径的性能分析、优化实验和保留/回退决定。
每项实验应尽量只改变一个主要因素，并同时记录运行环境、输入、线程配置、
耗时、正确性和 profiler 证据。

## 测试口径

- 正式平台：华为鲲鹏 920B（AArch64，TaiShan-v120）。
- 正式 CPU 路径：`TwoPunctureABE + ABE`。
- 正式输入：`GPU_Calculation="no"`，`Final_Evolution_Time=40.0`。
- 正式计时：`AMSS_NCKU_Program.py` 输出的 `This Program Cost`。
- 正式正确性：完整运行后执行 `./check.sh`。
- 短输入、缓存和限时采样只用于开发，不作为最终成绩。
- 当前交互式开发容器受 cgroup 限制，实际只有 4 CPU 配额；其中的墙钟时间
  不能与正式 30 核计算任务直接比较。

## 已知基线与热点

### TwoPunctureABE baseline

鲲鹏环境、`-O3 -g`、单线程完整采样：

| 指标 | 结果 |
|---|---:|
| 完整时间 | 约 292–297 s |
| IPC | 2.57 |
| L1D load miss | 2.67% |
| LLC load miss | 0.39% |

主要热点：

| 函数 | 占比 |
|---|---:|
| `TwoPunctures::LineRelax_be` | 27.46% |
| `__cos` | 22.92% |
| `TwoPunctures::LineRelax_al` | 19.08% |
| `TwoPunctures::ThomasAlgorithm` | 13.31% |
| `malloc/cfree` | 约 6% |

### ABE 快速采样（2026-08-11）

配置：短输入 `t=2`，30 MPI ranks，每 rank 1 OpenMP thread。采样发生在
只有 4 CPU 配额的开发容器中，因此 MPI 等待比例偏高。

- 样本数：138,057。
- 丢失样本：0。
- 原始数据：`profiling_results/quick_20260811/perf.abe.data`。
- 函数报告：`profiling_results/quick_20260811/perf.abe.self.txt`。
- 硬件计数器：`profiling_results/quick_20260811/perf.abe.stat`。

| 函数/模块 | 占比 | 说明 |
|---|---:|---|
| OpenPAL 内部轮询 | 约 66% | MPI progress/等待，受4核配额影响 |
| `libmpi` 内部 | 约 14% | MPI 通信或同步 |
| `compute_rhs_bssn_` | 4.53% | 最大的真实计算热点 |
| `polint_` | 1.48% | 插值热点 |
| `lopsided_._omp_fn.0` | 1.06% | 偏置差分 |
| `fdderivs_._omp_fn.0` | 1.03% | 二阶导数 |
| `kodis_._omp_fn.0` | 0.68% | 人工耗散 |
| `fderivs_._omp_fn.0` | 0.46% | 一阶导数 |

累计 `perf stat` 指标：IPC 1.94、branch miss 0.82%、L1D miss 0.13%、
LLC load miss 37.31%、实际利用 3.861 CPUs。该次运行被主动中止，只用于定位
热点，不用于性能或正确性结论。

## 优化记录

### O1：TwoPuncture workspace、三角函数预计算与 OpenMP

状态：**保留**。

主要修改：

- 为 `LineRelax_be`、`LineRelax_al` 和 `ThomasAlgorithm` 建立每线程 workspace，
  避免热路径反复 `new[]/delete[]`。
- 预计算只依赖网格索引的 `sin/cos` 和相关因子。
- 对相互独立的 line relaxation 外层任务使用 OpenMP。

计算节点线程扩展结果：

| OpenMP threads | TwoPuncture 时间 |
|---:|---:|
| 1 | 292 s |
| 2 | 209 s |
| 4 | 165 s |
| 8 | 141 s |
| 16 | 127 s |
| 30 | 117 s |

相对单线程加速约 `292 / 117 = 2.50x`。最终选择30线程。

### O2：ABE MPI rank 数测试

状态：**30 ranks 暂时保留**。

配置：短输入 `t=2`，每 rank 1 OpenMP thread。

| MPI ranks | ABE 时间 |
|---:|---:|
| 30 | 90 s |
| 20 | 94 s |
| 15 | 100 s |
| 10 | 110 s |
| 9 | 120 s |
| 6 | 98 s |

短输入下30 ranks 最快。正式 `t=40` 仍需复测，因为长演化中的计算/通信比例
可能不同。

### O3：ABE MPI/OpenMP 组合测试

状态：**ABE 每 rank 1线程；不继续扩大细粒度 OpenMP**。

| MPI × OMP | ABE 时间 |
|---:|---:|
| 30 × 1 | 88 s |
| 30 × 2 | 87 s |
| 15 × 2 | 96 s |
| 15 × 4 | 102 s |
| 10 × 3 | 113 s |
| 10 × 6 | 109 s |

`30×2` 相对 `30×1` 只有1秒差异，无法证明稳定收益；其他混合配置更慢。

### O4：分离 TwoPuncture 与 ABE 的线程数

状态：**保留，等待正式端到端复测**。

问题：`AMSS_NCKU_Program.py` 将输入中的 `OMP_threads=30` 全局写入环境，ABE
的每个 MPI rank 也继承30线程。加入 Fortran OpenMP 后可能形成
`30 MPI × 30 OMP = 900` 个软件线程。

修改：

- `scripts/makefile_and_run.py` 为 ABE 增加独立线程配置。
- ABE 默认使用 `AMSS_ABE_OMP_THREADS=1`。
- TwoPuncture 继续使用输入中的 `OMP_threads=30`。
- 可通过环境变量显式测试其他混合配置，例如：

  ```bash
  AMSS_ABE_OMP_THREADS=2 ./run.sh
  ```

验证：Python 语法检查、默认/覆盖命令生成和完整增量编译均通过。

### O5：消除 `polint` 的数组区段临时量

状态：**保留**。

日期：2026-08-14。

证据：快速采样中 `polint_` 占 ABE 总样本的 1.48%。该函数从 OpenMP
并行的 prolongation 路径被高频调用；原实现每个 Neville 插值阶段都通过
数组区段生成 `den`、更新 `c/d`，可能产生小型临时数组和运行时开销。

修改：

- 文件：`src/fmisc.f90`。
- 删除临时数组 `den(ordn)`，改用标量 `den`。
- 将每个插值阶段的数组区段表达式改为原地标量循环。
- 保持 `ho` 的计算、Neville 阶段顺序、分支选择和 `y=y+dy` 累加顺序不变。

4 CPU 配额容器的一步预筛选：

| 版本 | Total Running Time |
|---|---:|
| 原数组区段实现 | 67.97 s |
| 标量循环实现 | 60.16 s |

正式 `lab4` 计算节点、`t=2`、30 MPI ranks × 1 OMP thread：

| 版本/作业 | ABE Total Running | 端到端时间 |
|---|---:|---:|
| 近期基线 `j91722` | 88.93 s | 207.60 s |
| 近期基线 `j91243` | 89.78 s | 209.73 s |
| 近期基线 `j91677` | 90.45 s | 210.98 s |
| 优化 `j93894` | 70.20 s | 191.91 s |
| 优化确认 `j93906` | 70.42 s | 190.11 s |

相对最佳近期基线，ABE 缩短约20.8%，端到端缩短约7.5%；两次优化运行的
ABE 时间相差0.32%，结果稳定。

正确性：一步 A/B 的四个关键 `.dat` 文件除创建时间戳外均位级一致；以原
一步输出为参考运行 checker，trajectory RMS 为0，constraints 通过。计算节点
短运行的 constraints 通过；trajectory 失败仅因为 `t=2` 覆盖2/100个正式时间点，
不是数值误差。最终仍需用 `t=40` 完整验证。

### O6：插值缓冲区原位归约与积分归约合并

状态：**保留，正式长跑收益待确认**。

日期：2026-08-14。

鲲鹏计算节点 `t=2` 的采样显示，`AnalysisStuff -> surf_MassPAng -> Interp_Points -> MPI_Allreduce` 是主要等待路径。修改：

- `src/MPatch.C`：CPU 多点插值直接复用调用者的 `Shellf` 缓冲区，并使用 `MPI_IN_PLACE` 归约；全局 communicator 与局部 communicator 两个重载同步修改，避免每次分析分配和写入第二个 `NN*num_var` 大数组。
- `src/surface_integral.C`：将质量、三分量线动量、三分量角动量的7次标量 `MPI_Allreduce` 合并为一次长度7的归约；两种 communicator 重载同步修改。

验证：CPU 增量编译通过。30 MPI ranks × 1 OpenMP thread、TwoPuncture 缓存、`t=2`：

| 运行 | Before Evolve | Total Evolve | Total Running |
|---|---:|---:|---:|
| 修改前采样运行 | 3.443 s | 68.662 s | 72.106 s |
| 修改后 `j94431` | 0.625 s | 70.144 s | 70.769 s |
| 修改后 `j94445` | 0.619 s | 68.999 s | 69.618 s |

修改后两次 Total Running 中位数约70.19秒，与O5未插桩结果70.20--70.42秒接近；目前只能确认无稳定回退，不能宣称显著端到端加速。初始化阶段的临时缓冲开销明显降低。

正确性：两次运行均成功；以修改前 `t=2` 输出为基准，checker 的 trajectory RMS 为0、constraints PASS、FINAL PASS；四个关键 `.dat` 文件除时间戳外数值文本位级一致。

### R1：关闭 `compute_rhs_bssn` 全数组 NaN sanity check

状态：**已回退**。

假设：每次 RHS 调用开头对约22个三维数组执行 `sum()` 会造成额外内存扫描。

测试：4 CPU 配额容器，4 MPI ranks，1步演化。

| 版本 | Total Running Time |
|---|---:|
| sanity check 开启 | 56.71 s |
| sanity check 关闭 #1 | 58.08 s |
| sanity check 关闭 #2 | 56.97 s |

没有测得稳定收益，按“一次一项、负优化回退”原则恢复原实现。

### R2：使用 `-mcpu=native`

状态：**已回退**。

假设：利用 TaiShan-v120 的 SVE 和目标相关指令调度。

相同一步测试从约56.7秒变为64.4秒，约慢13.6%。推测 GCC 生成的 native/SVE
代码不适合当前多数组表达式或增加了额外开销。构建已恢复为：

```text
AMSS_OPT=-O3 -g
AMSS_ARCH_FLAGS=
```

### R3：融合6个度规 RHS 数组表达式

状态：**已回退**。

假设：在一个逐点循环中同时生成 `gxx_rhs`、`gyy_rhs`、`gzz_rhs`、
`gxy_rhs`、`gyz_rhs`、`gxz_rhs`，复用公共输入并减少数组扫描。

结果：融合版56.87秒，参考版56.71秒，约慢0.3%；一步关键输出也不是位级一致。
未观察到性能收益，因此恢复原数组表达式。

## 当前推荐配置

### O7：表面积分 Reduce-scatter 与混合 MPI/OpenMP

状态：**保留；推荐 ABE 使用 30 MPI ranks × 2 OpenMP threads**。

日期：2026-08-14。

实现：

- `src/MPatch.C/.h`：增加共享插值实现和 `Interp_Points_ReduceScatter`，表面积分只把每个 rank 负责的连续点段归约到该 rank，避免所有 rank 都接收完整的 `n_tot × 17` 插值数组。
- `src/MPatch.C`：CPU 插值点循环加入 `omp parallel for schedule(static)`；坐标、block 边界和变量链表游标均为线程局部变量。
- `src/surface_integral.C`：CPU `surf_MassPAng` 使用局部 Reduce-scatter 结果；GPU 仍使用原 Allreduce 路径。质量、线动量和角动量的7个标量继续使用O6合并后的单次归约。
- `scripts/makefile_and_run.py`：支持 `AMSS_ABE_MPI_PROCESSES` 与 `AMSS_ABE_OMP_THREADS`，允许不修改输入文件就测试 MPI/OpenMP 组合。

平台：lab4 分配的60个逻辑CPU对应30个物理核、SMT2。混合运行必须按硬件线程绑核：

```bash
AMSS_MPIEXEC="mpiexec --allow-run-as-root --use-hwthread-cpus --map-by slot:PE=2 --bind-to hwthread" AMSS_ABE_MPI_PROCESSES=30 AMSS_ABE_OMP_THREADS=2 OMP_PROC_BIND=close OMP_PLACES=threads ./run.sh --twop-cache
```

短输入 `t=2`、TwoPuncture cache 的结果：

| 配置/作业 | Before Evolve | Total Evolve | Total Running | 正确性 |
|---|---:|---:|---:|---|
| O6 `30×1`, `j94445` | 0.619 s | 68.999 s | 69.618 s | PASS、四文件位级一致 |
| Reduce-scatter `30×1`, `j94558` | 3.707 s | 69.290 s | 72.997 s | PASS、四文件位级一致 |
| `30×2`, `j94593` | 3.648 s | 57.072 s | 60.720 s | PASS、四文件位级一致 |
| `30×2`, `j94611` | 0.625 s | 58.733 s | 59.359 s | PASS、四文件位级一致 |
| `20×3`, `j94599` | 3.874 s | 71.118 s | 74.992 s | checker PASS；Psi4文本因rank归约顺序不同 |
| `15×4`, `j94605` | 4.179 s | 74.042 s | 78.220 s | FAIL，trajectory RMS 11.84% |

两次 `30×2` 的 Total Evolve 中位数为57.902秒，Total Running 中位数为60.039秒。相对最佳O6 `30×1`，演化墙钟时间减少约16.1%（1.19x），总运行时间减少约13.8%（1.16x）。

`15×1` 诊断作业 `j94615` 同样出现 trajectory RMS 11.84%，证明 `15×4` 的正确性失败来自15-rank 的既有网格/黑洞追踪分解，而不是4线程插值竞态。15-rank 配置不可用于正式结果。

注意：每步日志中的 `Computer used` 使用 `clock()`，多线程下会累计线程CPU时间；混合配置的性能比较必须使用基于 `MPI_Wtime()` 的 `Total Evolve` 和 `Total Running`。

当前结论：Reduce-scatter 单独在 `30×1` 未显示稳定收益，但与线程安全的插值并行结合后，`30×2` 获得可重复收益且位级正确，因此整组修改保留。正式 `t=40` 前仍需做完整端到端复测。

### O8：表面积分 owner-local 与非对称 OpenMP

状态：**保留为当前最佳候选；正式 `t=40` 待验证**。

日期：2026-08-14。

新采样 `test_archives/perf_20260814_091601`（30 MPI × 2 OMP）获得208K cycles样本且零丢失。`Patch::Interp_Points_Impl -> MPI_Reduce_scatter` 占约43% inclusive；实际插值只出现在两个TID中，说明表面点集中由一个MPI rank的两个OpenMP线程计算，其余rank主要在collective中等待。真实计算self热点为 `compute_rhs_bssn_` 8.52%、插值worker 3.41%、`lopsided` 3.34%、`fdderivs` 2.93%、`polint_` 1.62%。

实现：

- `src/MPatch.C/.h` 增加 owner-local 插值出口，返回本rank拥有的点和值，不再归约整个 `n_tot × 17` 场。
- `src/surface_integral.C` 的 `owner_local` 路径直接积分本地拥有点，最后只保留7个标量的 `MPI_Allreduce`。
- `AMSS_SURFACE_OMP_THREADS` 只扩大拥有表面点的rank的插值线程组；不拥有点的rank使用单线程扫描。
- 运行时可通过 `AMSS_SURFACE_COLLECTIVE=reduce_scatter|allreduce|owner_local` 做同一二进制A/B；默认仍为 `reduce_scatter`，避免未验证平台行为变化。

短输入 `t=2`、30 MPI × 2 OMP结果：

| 表面路径/线程 | Total Evolve | Total Running | 正确性 |
|---|---:|---:|---|
| tuned Reduce-scatter, 2线程 | 56.738 s | 57.302 s | PASS、四文件位级一致 |
| Allreduce, 2线程 | 56.948 s | 60.746 s | PASS、四文件位级一致 |
| owner-local, 2线程 | 56.683 s | 57.277 s | PASS、四文件位级一致 |
| owner-local, 8线程 | 46.818 s | 47.502 s | PASS、四文件位级一致 |
| owner-local, 16线程 #1 | 40.554 s | 41.322 s | PASS、四文件位级一致 |
| owner-local, 16线程 #2 | 34.439 s | 38.223 s | PASS、四文件位级一致 |
| owner-local, 30线程 | 42.477 s | 46.180 s | PASS、四文件位级一致 |

16线程两次 Total Evolve 中位数37.496秒，Total Running中位数39.772秒。相对O7 `30×2` 中位数，演化时间减少35.2%（1.54x）；相对O6最佳 `30×1`，演化时间减少45.7%（1.84x）。unbound调度存在明显波动，因此必须以重复结果和中位数报告。

推荐短跑命令：

```bash
AMSS_ABE_MPI_PROCESSES=30 AMSS_ABE_OMP_THREADS=2 AMSS_SURFACE_COLLECTIVE=owner_local AMSS_SURFACE_OMP_THREADS=16 AMSS_MPIEXEC="mpiexec --allow-run-as-root --use-hwthread-cpus --map-by slot --bind-to none --mca mpi_yield_when_idle 1" OMP_PROC_BIND=false ./run.sh --twop-cache
```

优化后采样 `test_archives/perf_20260814_094917` 收集280K样本且零丢失，但perf显著扰动unbound调度，不能用其墙钟时间比较。大字段Reduce-scatter已消失；最终7标量Allreduce仍有约41% inclusive等待，OpenMP barrier约19.64% self，`compute_rhs_bssn_` 约8.41% self，插值worker约2.62%。这说明下一目标不是继续调collective，而是缓存固定表面点的插值stencil与权重，减少 owner rank 的 `global_interp/polin3/polint` 重复工作。

```text
TwoPunctureABE: OMP_NUM_THREADS=30
ABE:             MPI ranks=30, OMP_NUM_THREADS=2, unbound + MPI wait yielding
Surface integral: owner_local, AMSS_SURFACE_OMP_THREADS=16
Compiler:        GNU, -O3 -g, no architecture-specific flag
```

当前输入仍是短运行调试配置：`Final_Evolution_Time=2.0`。正式测试前必须恢复
CPU 规定值 `40.0`。

## O9：合并 lopsided + kodis 调用

状态：**保留**。

日期：2026-08-15。

profiler 证据（`test_archives/perf_record_20260815_060337`，O8 配置 `t=2`）：

| 符号 | self% |
|---|---:|
| `compute_rhs_bssn_` | 17.49% |
| `lopsided_._omp_fn.0` | 5.43% |
| `fdderivs_._omp_fn.0` | 5.04% |
| `kodis_._omp_fn.0` | 3.29% |
| `__memset_sve_zva64` | 3.72% |
| `__memcpy_sve` | 3.70% |
| `malloc` + `cfree` | 2.88% |
| `polint_` | 3.50% |

`compute_rhs_bssn` 中原有 24 次 `lopsided` + 21 次 `kodis` = 45 次独立调用，每次各执行
一次 `symmetry_bd`（全数组拷贝 + ghost fill）和一次 OpenMP fork-join。其中 21 个变量在
lopsided 和 kodis 中使用同一输入数组，存在冗余。

修改：

- `src/lopsidediff.f90`：新增 `lopsided_kodis` 合并子程序，对同一变量只执行一次
  `symmetry_bd`，并在单个 `!$omp parallel` 区域内依次完成 advection（`!$omp do`）和
  dissipation（`!$omp do`）。kodis 逻辑直接内联，不依赖 `kodiss.f90`。
- `src/bssn_rhs.f90`：将 21 对可合并的 `lopsided` + `kodis` 调用替换为单次
  `lopsided_kodis`；保留 3 对不可合并的 `gxx/dxx`、`gyy/dyy`、`gzz/dzz`（lopsided 用
  `gxx=dxx+1`，kodis 用 `dxx`，输入不同）。

效果：`symmetry_bd` 调用从 45 次减至 27 次；OpenMP fork-join 从 45 次减至 27 次。

短输入 `t=2`、30 MPI × 2 OMP、owner-local 16 线程、TwoPuncture cache：

| 运行 | Total Evolve | Total Running | 正确性 |
|---|---:|---:|---|
| perf 基线 `perf_record_20260815` | 50.98 s | 51.77 s | — |
| O9 `j98003` | 38.07 s | 42.30 s | PASS, trajectory RMS=0, constraints PASS |

相对 perf 基线，Total Evolve 减少 25.3%（1.34x），Total Running 减少 18.3%（1.22x）。
四次关键 `.dat` 文件位级一致（trajectory RMS=0）。

注意：perf 基线有 perf 采样扰动，实际无插桩收益可能略小于上述数字。需未插桩
重复运行确认。

## R4：缓存表面点 block 查找

状态：**已回退**。

日期：2026-08-15。

假设：profiler 显示 `polint_` 占 3.50%，`global_interp` 中每步每个表面点都要
遍历 block 链表查找 owning block。缓存 block 指针可消除重复遍历。

修改：

- `src/MPatch.h`：增加 `interp_cache` 结构，缓存每个表面点的 owning `Block*`。
- `src/MPatch.C`：`Interp_Points_Impl` 首次调用时构建缓存，后续调用用缓存
  的 block 指针直接调用 `f_global_interp`，跳过链表遍历。每次仍验证 block bbox。

结果（`t=2`、30×2、owner-local 16线程）：

| 运行 | Total Evolve | Total Running |
|---|---:|---:|
| O9 基线 `j98003` | 38.07 s | 42.30 s |
| O10 `j98097` | 39.52 s | 43.39 s |

O10 比 O9 慢 3.8%（Total Evolve）。原因：level 0 的 block list 很短（1-2 个
block），原遍历几乎无开销；缓存的 bbox 验证反而引入了额外分支和内存访问。

按"一次一项、负优化回退"原则恢复 `MPatch.h`/`MPatch.C`。

## 下一步

1. 未插桩重复 O9 短跑，以中位数确认收益。
2. 探索 `compute_rhs_bssn_`（17.49%）中自动数组的 `allocatable, save` 预分配，
   减少 `malloc/cfree`（2.88%）和 `memset`（3.72%）开销。
3. 正式 `t=40` 长跑验证。

## 后续记录模板

```markdown
### O/R 编号：优化名称

状态：保留 / 回退 / 待验证

- 日期：
- commit/工作区状态：
- 假设与 profiler 证据：
- 修改文件和关键位置：
- 平台与资源：
- 输入：
- MPI × OMP、绑核：
- 编译器与完整参数：
- baseline（至少3次）：
- optimized（至少3次）：
- 中位数与加速比：
- 正确性结果：
- 决定与下一步：
```
