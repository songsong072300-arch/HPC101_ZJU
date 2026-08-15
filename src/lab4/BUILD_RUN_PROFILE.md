# Lab4 构建、运行与性能分析实战手册

本文件记录在 lab4 目录下**实际执行过**的构建、运行与 profiling 流程，
命令均已在鲲鹏 920B（aarch64）开发容器上验证通过。GPU 路径（A100）的
profiling 命令同步列出，但本机无 GPU，仅作命令参考。

---

## 0. 环境确认

```bash
# 架构与核心（本机为鲲鹏 920B，aarch64，任务一 CPU 平台）
uname -m && nproc

# CPU 拓扑与 NUMA（优化 MPI/OMP 绑核时必看）
lscpu | grep -iE "model name|architecture|numa|cpu\(s\)|thread|core|socket"
numactl --hardware

# 工具链
which perf mpiexec mpicxx g++ gfortran
perf --version

# GPU（任务二才有；本机无 GPU）
nvidia-smi -L

# perf 采样权限（root 不受影响；非 root 需要 <=1）
cat /proc/sys/kernel/perf_event_paranoid
```

本机实测：aarch64 / 鲲鹏 TaiShan-v120 / 4 NUMA 节点 / perf 6.12.95 / 无 GPU。
已有 `-O3` 无 OpenMP 的 baseline 构建（`AMSS_ENABLE_GPU=OFF`）。

---

## 1. 构建

```bash
./compile.sh
```

默认产物（位于 `build/`）：
- `TwoPunctureABE` — 双黑洞初值求解
- `ABE` — CPU BSSN 演化
- `ABEGPU` — GPU BSSN 演化（仅 amd64/A100 镜像默认开启）

### profiling 专用构建（保留调试符号）

perf 要把热点对应到函数/源码行，必须带 `-g`：

```bash
# 清掉旧缓存再重建（切换编译器/选项时务必换 build 目录）
rm -rf build && ./compile.sh -DAMSS_OPT='-O3 -g'
```

### 常用构建变体

```bash
./compile.sh -DAMSS_OPT='-O0'              # 调试版（关闭优化）
./compile.sh -DAMSS_ENABLE_OPENMP=ON       # 启用 OpenMP（需先在源码加 #pragma omp）
./compile.sh -DAMSS_MPI_CUDA_AWARE=1        # ABEGPU 走 CUDA-aware MPI 分支
```

> 切换编译器/MPI **必须**换新的 `AMSS_BUILD_DIR`，CMake 缓存了上次的编译器路径。

---

## 2. 运行

```bash
./run.sh
```

`run.sh` 流程：`ulimit -s unlimited` → 设置 OpenMPI root 变量 → 调用
`AMSS_NCKU_Program.py`，依次完成：读输入 → 生成 parfile → 跑 TwoPunctureABE →
跑 ABE/ABEGPU → 整理输出与画图。性能评分判据是 driver 打印的
`This Program Cost = ... Seconds`。

### CPU / GPU 切换

编辑 `AMSS_NCKU_Input.py`：

```python
GPU_Calculation  = "no"   # "no"=CPU(ABE), "yes"=GPU(ABEGPU)
MPI_processes    = 30     # MPI rank 数（GPU 建议先设 1）
OMP_threads      = 1      # 导出为 OMP_NUM_THREADS（baseline 无 OpenMP 区域）
```

CPU 演化时间默认 40.0，GPU 为 100.0。

### 缩短调试时间（lab4.md 明确允许调试时使用）

**你上次运行很久的原因**：CPU baseline 在计算节点上 t=40 约 340–500s，
加上 TwoPuncture 初值求解（数十秒），devpod 上更慢约 350 倍。三种加速手段：

**(a) 缓存 TwoPuncture 初值**（输入不变时跳过初值求解）：

```bash
./run.sh --twop-cache
```

首次运行会求解并缓存到 `twopuncture_cache/<hash>/`，之后命中缓存直接复制
`Ansorg.psid` 和 `puncture_parameters_new.txt`，跳过 TwoPunctureABE。
缓存 key 只依赖 `TwoPunctureinput.par`（物理参数），**改 `Final_Evolution_Time`
不会失效缓存**。正式评测禁用此选项，且勿提交 `twopuncture_cache/`。

**(b) 临时调小演化步数**（调试期验证编译/启动/跑通）：

```bash
cp AMSS_NCKU_Input.py AMSS_NCKU_Input.py.bak
# 把 Final_Evolution_Time 改成很小的值，例如 2.0 甚至 0.2
./run.sh --twop-cache
# 正式评测前必须恢复
mv AMSS_NCKU_Input.py.bak AMSS_NCKU_Input.py
```

**(c) 正式计时必须提交到计算节点**（devpod 仅用于开发/编译）：

```bash
# 任务一 CPU（鲲鹏 920B），lab4 分区给 30 物理核（60 线程）
hpc submit -p lab4 -c 60 ./run.sh

# 任务二 GPU（A100 MIG），单个 1g.10gb 实例
hpc submit -p lab4g10 -g 1 ./run.sh

# 交互式调试
hpc submit -p lab4 -c 60 --interactive bash
hpc submit -p lab4g10 -g 1 --interactive bash
```

### 正确性检查

```bash
./check.sh
```

要求：`bssn_BH.dat` 六个坐标列 RMS ≤ 0.1%；Grid Level 0 的 H/P 约束 ≤ 2.0。

### 输出位置

```
GW250118/AMSS_NCKU_output/        # bssn_BH.dat / bssn_ADMQs.dat / bssn_psi4.dat / bssn_constraint.dat
GW250118/AMSS_NCKU_output/binary_output/   # 原始二进制
GW250118/figure/                  # 图像（失败不影响数值结果）
```

---

## 3. 性能分析（Profiling）

按 lab4.md 标准流程：跑通 baseline → 记录 `This Program Cost` → profile 找热点 →
小改动 → `./check.sh` 验证 → 重新计时 → 重复。

**profiling 前务必带 `-g` 重新编译**：`./compile.sh -DAMSS_OPT='-O3 -g'`。

### 3.1 任务一 CPU 路径（鲲鹏 920B）— perf

`run.sh` 的进程链是 `bash → python → mpiexec → ABE`，perf 默认会跟随子进程。

#### (1) perf stat —— 硬件计数器总览

```bash
# 完整运行的总计数器
perf stat -d -- ./run.sh
# 或缓存命中后只测 ABE 阶段
perf stat -d -- ./run.sh --twop-cache
```

#### (2) perf record —— 采样热点与调用栈

```bash
perf record --call-graph dwarf -F 99 -- ./run.sh --twop-cache
perf report
```

#### (3) 对单个阶段直接采样

若 run.sh 采样开销大或受 MPI 启动限制，可直接对实际命令采样
（最终命令形如 `mpiexec -n 30 env OMP_NUM_THREADS=1 ./ABE`，见
`scripts/makefile_and_run.py:74`）：

```bash
# TwoPunctureABE（单进程，能完整跑完，适合快速 profile）
cd GW250118/AMSS_NCKU_output
perf stat -d -- ./TwoPunctureABE < /dev/null
perf record --call-graph dwarf -F 99 -o perf.twop.data -- ./TwoPunctureABE < /dev/null
perf report -i perf.twop.data --stdio --no-children -g none --percent-limit 1

# ABE 演化（30 rank，慢；可用 timeout 截取部分采样）
timeout -k 5 110 perf record -F 99 -o perf.abe.data -- \
  mpiexec --allow-run-as-root -n 30 env OMP_NUM_THREADS=1 ./ABE < /dev/null
perf report -i perf.abe.data --stdio --no-children -g none --percent-limit 1
```

#### 实测结果（鲲鹏 920B devpod，-O3 -g）

**TwoPunctureABE — perf stat**（完整运行 297s）：

| 指标 | 值 | 说明 |
|------|-----|------|
| task-clock | 296919 ms | 0.999 CPU 利用率 → **单线程**，OpenMP 优化目标 |
| IPC | 2.57 | 计算密集，无大停顿 |
| branch-misses | 1.24% | 正常 |
| L1-dcache-load-misses | 2.67% | 较低 |
| LLC-load-misses | 0.39% | 缓存友好 |

**TwoPunctureABE — 热点（perf report）**：

| 占比 | 符号 | 对应优化方向 |
|------|------|-------------|
| 27.46% | `TwoPunctures::LineRelax_be` | 线松弛预条件子，OpenMP 并行 |
| 22.92% | `__cos` (libm) | 标量数学库，替换/批处理 |
| 19.08% | `TwoPunctures::LineRelax_al` | 线松弛预条件子 |
| 13.31% | `TwoPunctures::ThomasAlgorithm` | 三对角求解 |
| 4.13% | `cfree` | 热路径动态分配，预分配复用 |
| 2.13% | `fourft` | FFT |
| 2.02% | `malloc` | 热路径动态分配 |

→ `LineRelax_be + LineRelax_al + ThomasAlgorithm` ≈ 60%（预条件子主导）；
`__cos + __sincos` ≈ 25%（标量数学函数）；`malloc/cfree` ≈ 6%（动态分配）。
完全对应 lab4.md 的 TwoPuncture 优化提示。

**ABE 演化 — 热点（devpod 上 timeout 截取 110s）**：

| 占比 | 符号 | 说明 |
|------|------|------|
| 61.49% | `libopen-pal` (opal_progress 等) | MPI 轮询/等待 |
| 16.33% | `libmpi` (MPI 内部) | MPI 同步 |
| 1.59% | `polint_` | ABE 计算函数 |

> devpod 慢且共享，30 rank 大量时间花在 MPI 等待；**真实计算节点上计算 kernel
> （`bssn_rhs.f90` 等）应占主导**。这正说明 profiling 必须在正式计算节点进行，
> devpod 结果仅供流程验证。

### 3.2 任务二 GPU 路径（A100 x86）— VTune + Nsight

本机无 GPU，以下为命令参考（在 A100 节点执行）。

#### Intel VTune —— 主机端调用链与等待

分析 `TwoPunctureABE + ABEGPU` 主机端热点、MPI/CUDA API 等待、线程活动。
多 rank 各用不同结果目录：

```bash
# 采集（在 A100 计算节点）
vtune -collect hotspots -result-dir vtune_r0 -- ./run.sh
# 下载 result-dir 到本地用 VTune GUI 查看 Summary / Bottom-up / Flame Graph / Threads
```

重点：`cuCtxSynchronize` 占用大说明主机在等 GPU，**不等于** kernel 跑那么久。

#### Nsight Systems —— CPU/MPI/GPU 全时间线

```bash
nsys profile -o lab4_baseline ./run.sh
nsys-ui lab4_baseline.nsys-rep    # 下载到本地 GUI 看
```

观察：kernel 执行时间/发射顺序、H2D/D2H、CPU 等 GPU、MPI 与 CUDA 是否串行、
kernel 是否碎片化、GPU 空闲区间。

#### Nsight Compute —— 单个热点 kernel 深入

先用 VTune/Nsight Systems 定位最耗时 kernel，再深入：

```bash
ncu --set full -o lab4_kernel -k <kernel_name> ./ABEGPU
```

分析：SM occupancy、global memory throughput、coalescing、register pressure、
shared memory、warp divergence、achieved vs 理论 occupancy。

---

## 4. 常见问题与注意事项

1. **devpod 太慢**：devpod 比计算节点慢约 350 倍，ABE 演化即使 t=0.2 也跑不完。
   devpod 只用于编辑/编译/短时调试，正式计时必须 `hpc submit` 到计算节点。

2. **perf record 报 "Permission error mapping pages"**：mlock 不足。
   本机 `/proc/sys` 只读无法调大 `perf_event_mlock_kb`，回退用小 mmap：
   `perf record -m 4 ...`（牺牲 dwarf 调用图，仍能得到函数级热点）。

3. **TwoPuncture 缓存失效**：缓存 key 依赖物理参数（质量/位置/动量/自旋），
   改这些会重新求解；改 `Final_Evolution_Time`/`MPI_processes`/`OMP_threads` 不影响。

4. **正式评测前必恢复**：`Final_Evolution_Time`（CPU 40.0 / GPU 100.0）、
   删除 `twopuncture_cache/`、不依赖缩短时间得到的性能数据。

5. **profiling 结论以计算节点为准**：devpod 上 ABE 的 MPI 等待占比虚高，
   真实热点应在计算节点重新 profile。

6. **评分判据**：`AMSS_NCKU_Program.py` 输出的 `This Program Cost = ... Seconds`，
   任务一 340s→100 分 / 500s→60 分；任务二三次函数拟合，满分 120（含 20 bonus）。
