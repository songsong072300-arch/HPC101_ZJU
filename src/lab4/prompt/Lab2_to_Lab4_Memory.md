# Lab4 优化记忆：从 Lab2 迁移到 BiCGSTAB

## 1. 文档目的

本文记录 Lab2 优化过程中已经验证过的方法论，并结合 Lab4 当前的
BiCGSTAB 实现，说明哪些经验可以直接迁移、哪些需要重新实验、哪些不应照搬。

这不是一份“所有技巧都打开”的清单。后续每次改动都应遵循：

1. 建立可重复的基线；
2. 用 profile 确认热点；
3. 一次只改变一个主要因素；
4. 同时记录时间、迭代次数和最终相对残差；
5. 负优化或精度失败立即回退，并把结论写入 history。

Lab4 当前入口为 `src/bicgstab/solver.c`，计时范围覆盖整个 `bicgstab()`。
`src/main.cpp` 的计时区、`src/judger.cpp` 和 `include/judger.h` 不允许修改。

---

## 2. 当前程序的数学控制流

当前使用 Jacobi 对角预条件器：

$$
M^{-1}_{ii}=\frac{1}{A_{ii}}.
$$

初始化为：

$$
r_0=b-Ax_0,\qquad \hat r_0=r_0,\qquad p_0=r_0.
$$

每轮 BiCGSTAB 主要执行：

$$
y=M^{-1}p,\qquad v=Ay,
$$

$$
\alpha=\frac{\rho}{(\hat r_0,v)},\qquad
s=r-\alpha v,
$$

$$
z=M^{-1}s,\qquad t=Az,
$$

$$
\omega=\frac{(t,s)}{(t,t)},
$$

$$
x\leftarrow x+\alpha y+\omega z,
\qquad r\leftarrow s-\omega t,
$$

$$
\rho_{new}=(\hat r_0,r),\qquad
\beta=\frac{\rho_{new}}{\rho}\frac{\alpha}{\omega},
$$

$$
p\leftarrow r+\beta(p-\omega v).
$$

每轮有两次稠密 GEMV：`A*y` 和 `A*z`。它们的计算量约为
$4N^2$ FLOP，远高于若干个 $O(N)$ 向量循环。

对于足够大的稠密矩阵，一次 GEMV 至少读取约 $8N^2$ 字节的矩阵数据，
算术强度近似为：

$$
I\approx\frac{2N^2\ \mathrm{FLOP}}{8N^2\ \mathrm{Byte}}
=0.25\ \mathrm{FLOP/Byte}.
$$

因此大规模 Lab4 很可能首先受内存带宽限制，而不是受浮点乘加吞吐限制。
这个结论必须用 profile 和硬件计数器验证，但它决定了后续优化的优先级：
减少 GEMV 次数或矩阵流量通常比替换一条标量指令更重要。

---

## 3. Lab2 中可以直接迁移的方法论

### 3.1 先重构数据流，再写 SIMD

Lab2 最大的早期收益来自先把逐 token、逐 expert 的零散计算重构成批处理，
而不是立即手写 AVX/AMX。Lab4 也应先消除重复向量遍历和不必要的中间数组，
再优化单个循环。

应优先寻找以下模式：

- 产生一个向量后马上对它做 dot/norm；
- 连续多个循环读取相同的 `x/r/s/t`；
- 只为下一步建立的临时向量；
- 同一轮重复计算相同范数；
- GEMV 已经产生 `y[i]`，随后又单独遍历 `y` 做归约。

### 3.2 归约使用多条独立累加链

Lab2 的 `dot_f32`、`dot_i8` 证明，单累加器会形成循环携带依赖。Lab4 的
FP64 dot product 和 GEMV 行内归约同样适用：

```c
__m512d sum0 = _mm512_setzero_pd();
__m512d sum1 = _mm512_setzero_pd();
__m512d sum2 = _mm512_setzero_pd();
__m512d sum3 = _mm512_setzero_pd();
```

循环内轮流使用四个累加器，循环结束后再树形合并。AVX2 可使用四个
`__m256d`。具体采用 2、4 还是 8 条链要查看生成汇编和寄存器溢出，不能仅凭理论决定。

### 3.3 融合“生成向量”和“归约向量”

只要每个输出元素独立，生成时就可以顺便累加 dot 或 norm，减少一次完整内存扫描。
这是 Lab4 最值得迁移的 Lab2 技巧之一。

### 3.4 线程私有部分和，最后确定性合并

Lab2 中共享计数器的 atomic 会导致 cache-line bouncing，最终改成线程私有计数后
再合并。Lab4 的 dot/norm 也应使用线程私有、Cache-Line 对齐的部分和：

```text
thread 0 -> partial[0][padding]
thread 1 -> partial[1][padding]
...
single thread -> 按固定线程顺序合并
```

这样既避免 atomic，又可比 OpenMP reduction 更容易控制浮点累加顺序。
由于判定容差是 $10^{-12}$，归约顺序变化可能改变收敛轮数，必须记录。

### 3.5 线程数由瓶颈和物理核心决定

Lab2 已验证“16 个逻辑线程”不等于“16 份独立执行资源”。SMT sibling 会共享
前端、缓存、内存带宽和向量执行单元。Lab4 的大型 GEMV 可能先打满内存带宽，
因此线程数达到某个值后会饱和，甚至下降。

必须分别测试 1、2、4、8、16 线程，并配合：

```bash
OMP_PLACES=cores
OMP_PROC_BIND=close
```

最终选择墙钟时间最短的线程数，而不是 CPU 利用率最高的线程数。

### 3.6 使用形状阈值保留多条路径

Lab2 的单 token 与批量 token 最终需要不同内核。Lab4 也可能需要：

- 小 $N$：串行或少线程 AVX 内核；
- 中等 $N$：OpenMP + SIMD，矩阵可能驻留 LLC；
- 大 $N$：内存带宽主导，使用全部物理核或 NUMA 分区；
- 稀疏/带状矩阵：完全不同的数据结构和 SpMV 内核。

不能假设一个线程数、一个行块大小适合全部测试数据。

### 3.7 以重复 A/B 中位数判断优化

Lab2 后期大量“理论上更快”的实现最终是负优化，包括更多线程、显式 copy、
分支复制、过度展开和持久线程池。Lab4 也必须采用交错 A/B，而不是比较两次孤立运行。

建议每项记录：

| 字段 | 内容 |
|---|---|
| 数据集与 $N$ | 明确输入规模 |
| 编译器与参数 | GCC/Clang/ICC、`-march` 等 |
| 线程与绑核 | `OMP_NUM_THREADS`、places、bind |
| elapsed | 至少 5 次中位数 |
| iterations | 收敛轮数是否改变 |
| relative residual | 必须小于 $10^{-12}$ |
| profile | GEMV、归约、同步、内存比例 |

---

## 4. Lab4 第一阶段应做的数据流融合

### 4.1 初始化融合

当前初始化依次执行：

```text
r = A*x
r = b-r
r_hat = r
p = r
rho = dot(r_hat,r)
```

GEMV 之后的四项可以在一次 $O(N)$ 循环中完成：

```c
ri = b[i] - Ax[i];
r[i] = ri;
r_hat[i] = ri;
p[i] = ri;
rho_partial += ri * ri;
```

由于评测器初始化 `x=0`，理论上首次 `A*x` 恒为零，可以直接令 `r=b`。
但是否利用这一条件要看 OJ 是否保证所有调用都使用零初值。若只由当前 `main.cpp`
调用，则这是合法优化；若要求 `bicgstab()` 是通用接口，应保留非零初值路径。

### 4.2 GEMV 与 dot 融合

计算：

$$
v=Ay,\qquad d=(\hat r_0,v)
$$

时，`v[i]` 一旦完成便可立即执行：

```c
denom_partial += r_hat[i] * v[i];
```

因此可提供：

```c
double gemv_dot(double *v, const double *A, const double *y,
                const double *r_hat, int N);
```

同理，第二次 GEMV 可以同时计算：

$$
t=Az,\qquad ts=(t,s),\qquad tt=(t,t).
$$

对应：

```c
void gemv_dot2(double *t, const double *A, const double *z,
               const double *s, int N,
               double *ts, double *tt);
```

这样每轮可消除三次额外的 $O(N)$ dot 扫描。

### 4.3 向量更新与 norm 融合

以下两项应在同一个循环中完成：

$$
s=r-\alpha v,\qquad ss=(s,s).
$$

第二阶段也应融合：

$$
x\leftarrow x+\alpha y+\omega z,
$$

$$
r\leftarrow s-\omega t,
$$

$$
rr=(r,r),\qquad \rho_{new}=(\hat r_0,r).
$$

一次循环同时更新 `x/r` 并产生两个线程私有部分和。

### 4.4 删除 `h` 中间数组

当前：

$$
h=x+\alpha y,
$$

随后又计算：

$$
x=h+\omega z.
$$

正常路径可以直接写成：

$$
x\leftarrow x+\alpha y+\omega z,
$$

从而删除 `h` 的分配、写入和读取。若 `s` 已经收敛，则执行一次：

$$
x\leftarrow x+\alpha y
$$

后退出即可。

### 4.5 复用已经计算的残差范数

当前每 1000 轮打印时会再次执行 `dot_product(r,r)`。应保存上一轮检查得到的
`rr`，打印 `sqrt(rr)`，不要为日志增加一次向量扫描。

---

## 5. GEMV 的 SIMD 与缓存优化

### 5.1 基础 SIMD 行内核

矩阵当前按行优先存储，单行 `A[i*N+j]` 连续，已经适合 SIMD。基础实现应做到：

- `A`、`x`、`y` 使用 `const` 和 `restrict`；
- AVX-512 每次处理 8 个 FP64，AVX2 每次处理 4 个；
- 2～4 条独立 FMA 累加链；
- 标量处理尾部；
- 检查汇编中是否真正生成 packed FMA；
- 避免热循环中的函数调用和运行时 ISA 判断。

### 5.2 多行寄存器分块：把一串 dot 变成小型 GEMM

Lab2 中将一串 GEMV 合并为 GEMM 的思想可以迁移，但 Lab4 不需要转置整个矩阵。
可以一次计算 2、4 或 8 行：

```text
load x[j:j+VL] once
load A[i+0][j:j+VL] -> acc0
load A[i+1][j:j+VL] -> acc1
load A[i+2][j:j+VL] -> acc2
load A[i+3][j:j+VL] -> acc3
```

这能复用 `x` 的向量加载并提供多条独立累加链。代价是增加矩阵读流、寄存器压力和
水平归约数量。应 A/B 测试 `row_block=1/2/4/8`，并检查是否发生寄存器 spill。

### 5.3 不要盲目转置矩阵

当前行优先布局已经适合 `y=A*x`。简单转置会让每个输出 dot 变成跨行读取，通常更差。
只有当设计了明确的 panel-major 微内核，并证明一次打包成本能由大量迭代摊销时，
才考虑矩阵重排。

### 5.4 软件预取需要最后测试

顺序读取 `A` 时硬件预取器通常已经有效。手工 `_mm_prefetch` 可能污染缓存或消耗前端。
它应排在数据流融合、SIMD、线程和 NUMA 之后，并且只保留稳定收益。

### 5.5 关注 NUMA first-touch

`A` 在 `judger.cpp` 中由主线程分配并读取，页面可能首先落在单个 NUMA 节点。
如果使用跨 NUMA 的线程，远端读取可能限制 GEMV。

可比较：

- 只绑定单 socket；
- 跨 socket 运行；
- 在 `bicgstab()` 内并行复制到本地分片矩阵，再反复使用；
- MPI 每 rank 持有自己的行分片。

注意：Lab4 的复制发生在计时区内，只有迭代次数足够多时才可能摊销。

---

## 6. OpenMP 设计建议

### 6.1 GEMV 按输出行静态划分

稠密矩阵每行工作量相同，应优先使用：

```c
#pragma omp for schedule(static)
for (int i = 0; i < N; ++i) { ... }
```

`dynamic`/`guided` 会增加调度开销，除非矩阵被转换成每行非零数差异很大的稀疏格式。

### 6.2 尝试单一持久 parallel region，但必须 A/B

可以在 `bicgstab()` 迭代循环外创建一次 `#pragma omp parallel`，内部使用：

```text
omp for: y = M^-1 p
omp for: v = A y + partial dot
single : 合并 dot，计算 alpha
omp for: s + norm
single : 判断收敛
...
```

它能减少每轮反复 fork/join，但会增加 barrier 和 `single` 控制。Lab2 中“合并 parallel
region”曾出现负优化，因此这里只是候选方案。对于大 $N$，GEMV 足够重时 barrier 占比低；
对于小 $N$，应保留串行或较少线程路径。

### 6.3 避免伪共享

线程私有归约槽至少按 64 字节分隔。线程工作区也应按线程分块，避免多个核心写相邻元素。

### 6.4 不要默认使用 SMT

先找物理核心数，再逐级测试。若 8 线程已经达到内存带宽上限，16 个 SMT 线程通常不会翻倍。

---

## 7. 编译器与库

当前 CMake 使用 `-Og -g`，这适合调试但不适合性能提交。第一版性能基线至少应比较：

```text
-O3 -march=native -fopenmp
```

可进一步单独测试：

```text
-fno-math-errno
-fno-trapping-math
-funroll-loops
-ffast-math
```

其中 `-ffast-math` 会允许重排 FP64 运算，可能改变迭代轨迹甚至导致收敛失败，不能默认开启。

还应将手写 GEMV 与平台 BLAS 比较，例如 `cblas_dgemv` 或 MKL `dgemv`。需要注意：

- BLAS 自己可能创建线程，外层 OpenMP 与 BLAS 线程不能嵌套；
- 小矩阵的库调用开销可能超过收益；
- 大型 GEMV 通常受内存带宽限制，库实现不一定比简单的行并行内核快很多；
- 比较时必须固定 BLAS 线程数和 OpenMP 线程数。

---

## 8. 首先检查矩阵结构，而不是默认它是普通稠密矩阵

文件以稠密格式存储，不代表矩阵在数值上一定稠密。拿到数据后应先统计：

- $N$；
- 非零比例和近零比例；
- 上下带宽；
- 是否对称或近似对称；
- 对角占优程度；
- 行范数分布；
- 是否存在固定 block、重复行块或 Kronecker 结构；
- Jacobi 预条件后的实际迭代数。

决策建议：

| 矩阵性质 | 候选优化 |
|---|---|
| 真正稠密 | SIMD/OpenMP GEMV、NUMA、BLAS |
| 非零比例很低 | 计时区内转换 CSR，并用迭代次数摊销 |
| 窄带矩阵 | banded storage，只读取带内元素 |
| 明显 block 结构 | block GEMV / block-Jacobi |
| Jacobi 收敛很慢 | 研究更强预条件器的构造成本与迭代收益 |

减少 BiCGSTAB 迭代次数通常比把单轮向量循环加速几个百分点更有价值。但更强预条件器
必须计入构造时间，且不能假设矩阵具有 SPD 等未声明性质。

---

## 9. MPI 的适用边界

若 Lab4 要求多节点，稠密矩阵可以按行分给 rank。每个 rank 保存自己的 $A$ 行和向量分片，
GEMV 后需要让后续所需向量在 rank 间保持一致，dot/norm 需要 `MPI_Allreduce`。

主要风险是每轮存在多个全局归约：

- $(\hat r_0,v)$；
- $(s,s)$；
- $(t,s)$ 与 $(t,t)$；
- $(r,r)$ 与 $(\hat r_0,r)$。

应把同一阶段的多个标量放进一个数组，用一次 `MPI_Allreduce` 合并。例如
`(t,s)` 与 `(t,t)` 可以一次归约，`(r,r)` 与新 `rho` 也可以一次归约。

通信优化必须保持数学依赖，不能把尚未产生的标量强行合并。单节点任务不要为了“使用 MPI”
引入额外通信层。

---

## 10. 不能直接从 Lab2 搬来的技巧

### 10.1 AMX-INT8 和激进量化

Lab4 使用 FP64，最终相对残差要求小于 $10^{-12}$。将矩阵或 Krylov 向量直接量化为 INT8、
BF16 或 FP16 极易破坏迭代稳定性。除非设计完整的 mixed-precision iterative refinement，
否则不要迁移 Lab2 的 INT8/AMX 路径。

### 10.2 近似除法、近似指数和位运算替换

BiCGSTAB 的 `alpha`、`omega`、`beta` 决定 Krylov 迭代轨迹。把 FP64 除法替换成低精度倒数，
可能增加迭代数、停滞或 breakdown。这里也没有值得近似的指数函数。

### 10.3 “线程越多越快”

Lab2 已明确否定这一点。Lab4 更可能受内存带宽限制，因此更应通过实测寻找饱和点。

### 10.4 手写 copy 一定比 libc 快

Lab2 中显式 AVX copy 多次出现回退。`memcpy` 对不重叠内存通常优于 `memmove`，但是否值得
替换应先看它在 profile 中的占比。更好的做法往往是通过融合彻底删除复制。

### 10.5 无条件展开和复制热函数

Lab2 的分支外提实验因代码体积和 I-cache 压力回退。Lab4 应先检查分支是否真的不可预测，
不要为了删除几个循环条件复制整套 GEMV 内核。

---

## 11. 推荐的实际优化顺序

### 阶段 0：建立基线

1. 使用当前 `-Og` 记录正确性、迭代数和时间；
2. 只改成 `-O3 -march=native`，作为优化编译基线；
3. 记录 CPU、NUMA、缓存、内存通道和可用 ISA；
4. 对不同数据集记录 $N$、迭代数和相对残差；
5. 使用 profiler 确认 GEMV 占比。

### 阶段 1：安全的数据流优化

1. 删除 `h`；
2. 初始化循环融合；
3. `s` 更新与 `s·s` 融合；
4. `t=Az` 与 `(t,s)/(t,t)` 融合；
5. `x/r` 更新与 `r·r/r_hat·r` 融合；
6. 复用打印所需残差；
7. 将不重叠的 `memmove` 改为 `memcpy`，或直接通过融合删除。

### 阶段 2：SIMD GEMV 与 dot

1. 让编译器自动向量化并查看 vectorization report；
2. 检查汇编；
3. 对比手写 AVX2/AVX-512；
4. 测试 1/2/4/8 行 blocking；
5. 检查寄存器 spill 和内存带宽。

### 阶段 3：OpenMP

1. GEMV 行静态并行；
2. 线程私有对齐归约；
3. 融合向量循环并行；
4. 测试 persistent parallel region；
5. 测试不同物理核心数和绑核方式；
6. 为小 $N$ 设置串行/少线程阈值。

### 阶段 4：矩阵结构与 NUMA

1. 分析稀疏性、带宽和 block 结构；
2. 测试单 socket 与跨 socket；
3. 评估矩阵复制/打包成本能否由迭代摊销；
4. 对比 BLAS；
5. 若允许多节点，再设计 MPI 行分片和合并归约。

### 阶段 5：算法级优化

1. 分析 Jacobi 预条件后的迭代数；
2. 仅在数据性质支持时测试 block-Jacobi、ILU 或结构化预条件；
3. 同时比较“预处理时间 + 迭代时间”，不能只比较单轮速度；
4. mixed precision 必须配合 FP64 残差校正，并作为高风险独立实验。

---

## 12. Profile 检查表

每次较大改动后至少回答：

1. 两次 GEMV 占总时间多少？
2. 实际内存带宽是否接近平台上限？
3. CPI 高是内存停顿、前端、归约依赖，还是同步等待？
4. OpenMP 平均并行度是多少？低并行度是任务不足还是 barrier 等待？
5. 线程是否落在独立物理核？
6. 是否跨 NUMA 远端读取 `A`？
7. 向量循环是否生成 FP64 SIMD FMA？
8. 是否存在 ZMM/YMM spill？
9. 优化是否改变迭代数？
10. 最终 relative residual 是否仍小于 $10^{-12}$？

Linux `perf stat` 可优先观察：

```text
task-clock, cycles, instructions, branches, branch-misses,
cache-references, cache-misses, LLC-loads, LLC-load-misses
```

若平台提供 VTune，应重点查看 Hotspots、Memory Access、线程时间线和 NUMA 访问。

---

## 13. 当前最值得实施的第一版

在尚未获得数据集 profile 前，风险最低、最可能稳定提升的组合是：

1. 编译参数从 `-Og` 改为 `-O3 -march=native -fopenmp`；
2. 保持 FP64 和原 BiCGSTAB 数学顺序；
3. 删除 `h`；
4. 融合 `s+norm`、`t+dot2`、`x+r+norm+rho`；
5. 使用多累加器 SIMD GEMV；
6. 对大型 $N$ 按行 `schedule(static)` 并行；
7. 使用线程私有对齐部分和；
8. 对 1/2/4/8/16 线程做绑定核心的 A/B；
9. 然后再决定是否需要矩阵 packing、BLAS、NUMA 或 MPI。

这一顺序沿用了 Lab2 最重要的经验：先减少工作和内存遍历，再提高单核效率，随后扩展到多核，
最后才处理高度场景化的缓存、硬件微内核和近似计算。
