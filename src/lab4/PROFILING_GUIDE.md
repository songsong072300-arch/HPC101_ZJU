# Lab4 性能分析速查（perf / VTune / Nsight）

模仿 lab2 的 profiling 工作流，适配 lab4 的 CPU（perf）与 GPU（VTune/Nsight）两套环境。
命令均在鲲鹏 920B 开发容器实测通过（GPU 命令为参考，需在 A100 节点执行）。

---

## 任务一：CPU 路径（鲲鹏 920B，perf）

> ARM 无 VTune、无 `--topdown`（x86 特性），用 `perf` 的 stat/record/report。

### 构建（profiling 版，带调试符号）

```bash
rm -rf build && ./compile.sh -DAMSS_OPT='-O3 -g'
```

### 确认正确性和耗时（缩短演化时间用于快速迭代）

```bash
# 备份并临时缩短演化时间（正式评测前必须恢复）
cp AMSS_NCKU_Input.py AMSS_NCKU_Input.py.bak
sed -i 's/Final_Evolution_Time.*/Final_Evolution_Time = 2.0  ## DEBUG/' AMSS_NCKU_Input.py

# 缓存 TwoPuncture 初值（之后命中缓存会跳过初值求解）
./run.sh --twop-cache

# 正确性检查
./check.sh
```

### 采集 TwoPunctureABE 热点（单进程，约 5 min 可完成）

TwoPunctureABE 不经 MPI，可像 lab2 那样直接采样：

```bash
cd GW250118/AMSS_NCKU_output

# 硬件计数器总览
perf stat -d -o perf.stat.twop.txt -- ./TwoPunctureABE < /dev/null
cat perf.stat.twop.txt

# 采样热点（本机 mlock 受限，用 -m 4；计算节点可去掉 -m 用 --call-graph dwarf）
perf record -m 4 -F 99 -o perf.twop.v1.data -- ./TwoPunctureABE < /dev/null
```

### CLI 查看

```bash
# 热点 Top 函数（类似 vtune -report hotspots）
perf report -i perf.twop.v1.data --stdio --no-children -g none --percent-limit 1

# 摘要（类似 vtune -report summary）
perf report -i perf.twop.v1.data --stdio --header

# 交互式 TUI
perf report -i perf.twop.v1.data
```

### 采集 ABE 演化热点（timeout 截取部分采样）

ABE 走 MPI 且很慢，用 `timeout` 截取一段：

```bash
cd GW250118/AMSS_NCKU_output

# 采样 ~100s（devpod 慢；计算节点可去掉 timeout 跑完整）
timeout -k 5 110 perf record -m 4 -F 99 -o perf.abe.v1.data -- \
  mpiexec --allow-run-as-root -n 30 env OMP_NUM_THREADS=1 ./ABE < /dev/null

# 清理可能的残留 rank
pkill -9 -f './ABE'; pkill -9 -f 'prterun'
```

### 硬件指标（替代 topdown）

ARM 无 topdown，用 `perf stat -d` 的 cache/branch/IPC 指标判断瓶颈类型：

```bash
perf stat -d -o perf.stat.abe.v1.txt -- \
  timeout 110 mpiexec --allow-run-as-root -n 30 env OMP_NUM_THREADS=1 ./ABE < /dev/null
cat perf.stat.abe.v1.txt
```

判断：IPC 低 + cache-miss 高 → 访存瓶颈；branch-miss 高 → 分支瓶颈；
MPI 等待占比高 → 通信瓶颈。

### 修改一个优化点后重新编译，并采集到新目录

```bash
# 在 src/ 改完代码后
./compile.sh -DAMSS_OPT='-O3 -g'

# 重新采集，用 v2/v3 命名迭代
cd GW250118/AMSS_NCKU_output
perf record -m 4 -F 99 -o perf.twop.v2.data -- ./TwoPunctureABE < /dev/null
perf report -i perf.twop.v2.data --stdio --no-children -g none --percent-limit 1

# 对比 v1 vs v2
perf diff perf.twop.v1.data perf.twop.v2.data --stdio --percent-limit 1
```

### 恢复正式输入

```bash
mv AMSS_NCKU_Input.py.bak AMSS_NCKU_Input.py
```

---

## 任务二：GPU 路径（A100，VTune + Nsight）

> A100 节点为 x86，有 VTune、Nsight Systems、Nsight Compute。

### 构建（GPU 版，带调试符号）

```bash
./compile.sh -DAMSS_ENABLE_GPU=ON -DAMSS_OPT='-O3 -g'
```

### 确认正确性和耗时

```bash
./run.sh --twop-cache
./check.sh
```

### 采集主机端热点（VTune Hotspots）

```bash
# 采集（约 5-10 min；正式跑用 hpc submit 提交）
vtune -collect hotspots -result-dir vtune-hotspots-v1 -- ./run.sh --twop-cache

# CLI 查看
vtune -report summary  -r vtune-hotspots-v1
vtune -report hotspots  -r vtune-hotspots-v1 | less
```

### 采集 CPU/MPI/GPU 全时间线（Nsight Systems）

```bash
nsys profile -o nsystime-v1 -- ./run.sh --twop-cache
# 下载 .nsys-rep 到本地用 nsys-ui GUI 查看
```

### 分析单个热点 kernel（Nsight Compute）

先用 VTune/Nsight Systems 定位最耗时 kernel，再深入：

```bash
ncu --set full -o ncu-bssn_rhs-v1 -k regex:bssn_rhs ./ABEGPU
# 或交互式
ncu --set full -k regex:bssn_rhs ./ABEGPU
```

### 修改优化点后重新编译，并采集到新目录

```bash
./compile.sh -DAMSS_ENABLE_GPU=ON -DAMSS_OPT='-O3 -g'

vtune -collect hotspots -result-dir vtune-hotspots-v2 -- ./run.sh --twop-cache
nsys profile -o nsystime-v2 -- ./run.sh --twop-cache
ncu --set full -o ncu-bssn_rhs-v2 -k regex:bssn_rhs ./ABEGPU
```

---

## 实测热点摘要（鲲鹏 920B devpod，-O3 -g，v1 baseline）

### TwoPunctureABE（perf stat，完整 297s）

| 指标 | 值 | 判断 |
|------|-----|------|
| CPU 利用率 | 0.999（单核） | **单线程，OpenMP 优化目标** |
| IPC | 2.57 | 计算密集，无大停顿 |
| L1-dcache-load-misses | 2.67% | 较低 |
| LLC-load-misses | 0.39% | 缓存友好 |

### TwoPunctureABE 热点 Top（perf report）

| 占比 | 符号 | 优化方向 |
|------|------|----------|
| 27.46% | `TwoPunctures::LineRelax_be` | 线松弛预条件子，OpenMP 并行 |
| 22.92% | `__cos` (libm) | 标量数学库，批处理/替换 |
| 19.08% | `TwoPunctures::LineRelax_al` | 线松弛预条件子 |
| 13.31% | `TwoPunctures::ThomasAlgorithm` | 三对角求解 |
| 4.13% | `cfree` | 热路径动态分配，预分配复用 |
| 2.02% | `malloc` | 热路径动态分配 |

→ 预条件子 ~60%、标量数学库 ~25%、动态分配 ~6%。

### ABE 演化热点（devpod timeout 110s，仅流程验证）

| 占比 | 符号 | 说明 |
|------|------|------|
| 61.49% | `libopen-pal` (opal_progress) | MPI 轮询/等待（devpod 虚高） |
| 16.33% | `libmpi` | MPI 同步 |
| 1.59% | `polint_` | ABE 计算函数 |

> devpod 上 MPI 等待占比虚高；**真实计算节点上计算 kernel（`bssn_rhs.f90` 等）应占主导**，
> profiling 结论必须以计算节点结果为准。

---

## lab2 → lab4 命令对照

| 步骤 | lab2 | lab4 CPU（perf） | lab4 GPU（VTune） |
|------|------|------------------|-------------------|
| 构建 | `cmake --build build -j` | `./compile.sh -DAMSS_OPT='-O3 -g'` | `./compile.sh -DAMSS_ENABLE_GPU=ON -DAMSS_OPT='-O3 -g'` |
| 跑+检查 | `./build/lab2 N... --benchmark` | `./run.sh --twop-cache && ./check.sh` | 同左 |
| 采集热点 | `vtune -collect hotspots -r dir -- exe` | `perf record -o perf.v1.data -- exe` | `vtune -collect hotspots -r dir -- ./run.sh` |
| 摘要 | `vtune -report summary -r dir` | `perf report -i perf.v1.data --stdio --header` | `vtune -report summary -r dir` |
| 热点列表 | `vtune -report hotspots -r dir` | `perf report -i perf.v1.data --stdio --no-children` | `vtune -report hotspots -r dir` |
| 硬件指标 | `perf stat --topdown --td-level 2` | `perf stat -d -- exe`（ARM 无 topdown） | `perf stat -d` / VTune |
| 迭代 | `vtune-hotspots-v5 / v6` | `perf.v2.data / v3.data` | `vtune-hotspots-v2 / v3` |
