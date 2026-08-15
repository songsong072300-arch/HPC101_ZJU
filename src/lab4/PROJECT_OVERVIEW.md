# Lab 4 项目通俗导读：AMSS-NCKU 数值相对论程序优化

## 1. 这个项目主要做什么？

一句话概括：**这个项目用计算机模拟两个黑洞的时空演化，并尝试在不改变计算结果的前提下，让整个模拟在 CPU 和 GPU 上运行得更快。**

项目来源于真实的数值相对论程序 AMSS-NCKU。课程使用的是经过裁剪的版本，以引力波事件 GW250118 为背景，构造了一个固定的双黑洞测试用例。它并不是要严格复现真实观测，而是让我们接触一套比较完整的高性能科学计算程序。

程序主要完成以下工作：

1. 读取两个黑洞的质量、位置、动量、网格和演化时间等参数；
2. 使用 `Ansorg-TwoPuncture` 方法计算双黑洞初始数据；
3. 在自适应网格上求解 BSSN 演化方程，推进黑洞系统随时间变化；
4. 使用有限差分计算空间导数，并使用 Runge-Kutta 方法推进时间；
5. 在不同网格层级之间插值和传递数据，并通过 MPI 交换边界（ghost zone）数据；
6. 输出黑洞轨迹、ADM 物理量、约束误差和引力波 `Psi4` 等结果；
7. 将结果与标准答案比较，确认优化没有破坏数值正确性。

不需要完整理解爱因斯坦方程或 BSSN 方程的物理推导。这个实验真正训练的是：**怎样阅读一个大型混合语言项目，使用性能分析工具找到瓶颈，再使用并行、向量化、访存和 GPU 优化手段缩短总运行时间。**

## 2. 程序是怎样运行的？

```text
AMSS_NCKU_Input.py
        │ 读取实验参数
        ▼
Python 脚本生成网格及输入文件
        │
        ▼
TwoPunctureABE
生成双黑洞初始数据
        │
        ▼
根据 GPU_Calculation 选择演化程序
        ├── no  ──► ABE（CPU + MPI，可加入 OpenMP）
        └── yes ──► ABEGPU（CUDA GPU + MPI）
        │
        ▼
输出黑洞轨迹、约束量、ADM 量和引力波数据
        │
        ▼
绘图，并由 check.sh 与 golden/ 标准结果比较
```

三个构建产物的作用如下：

| 可执行文件 | 作用 |
| --- | --- |
| `TwoPunctureABE` | 计算双黑洞的初始状态，CPU 和 GPU 两个任务都会执行它 |
| `ABE` | 在 CPU 上进行 BSSN 时间演化 |
| `ABEGPU` | 在 NVIDIA A100 GPU 上进行 BSSN 时间演化 |

本实验计算的是**端到端时间**。也就是说，初值生成、主演化、MPI 通信和必要的数据处理都会影响最终成绩。仅让一个小函数或一个 CUDA kernel 变快，不一定能让整个程序变快。

## 3. 项目使用了哪些技术？

| 技术 | 在项目中的作用 |
| --- | --- |
| Python | 读取参数、生成输入文件、启动程序、整理和绘制结果 |
| C++ | 主流程控制、网格和 Patch 管理、MPI 通信、数据管理及 I/O |
| Fortran | CPU 版本的主要数值计算 kernel |
| CUDA | GPU 版本的数值 kernel 和显存数据处理 |
| MPI | 将网格任务分给多个进程，并交换相邻区域数据 |
| OpenMP | baseline 尚未真正并行化，可用于增加 CPU 线程级并行 |
| AMR | 在黑洞附近使用细网格，在远处使用粗网格，降低总体计算量 |

当前固定数值设置包括：Patch 网格、cell-centered 布局、赤道对称、四阶有限差分、Runge-Kutta 时间推进，以及 vacuum BSSN 演化方程。

## 4. 最值得先读的项目入口

### 4.1 构建、运行和验证

| 文件 | 作用 | 是否可能优化 |
| --- | --- | --- |
| `CMakeLists.txt` | 决定编译哪些 CPU/GPU 文件以及优化、OpenMP、CUDA 架构等选项 | 是，编译参数和工具链会影响性能 |
| `compile.sh` | 调用 CMake 完成编译 | 是，可配合不同编译器和构建参数 |
| `run.sh` | 设置运行环境并启动 Python driver | 是，可配置线程、进程、绑核等运行环境 |
| `AMSS_NCKU_Input.py` | 保存 MPI、OpenMP、CPU/GPU 开关及固定物理参数 | **只能修改允许的并行和 GPU 参数** |
| `AMSS_NCKU_Program.py` | 串起输入生成、初值计算、主演化、输出整理和绘图 | 主要用于理解端到端流程 |
| `scripts/makefile_and_run.py` | 实际启动 `TwoPunctureABE`、`ABE` 或 `ABEGPU` | 用于理解 MPI rank 和环境变量如何传入 |
| `check.sh`、`scripts/check_result.py` | 将结果与 `golden/` 中的标准结果比较 | 每次重要优化后都应运行 |

最基本的使用方式是：

```bash
./compile.sh
./run.sh
./check.sh
```

## 5. 真正需要重点优化的源文件

下面是阅读入口，不代表这些文件一定都是当前机器上的性能热点。**最终修改顺序应由 `perf`、VTune、Nsight Systems 和 Nsight Compute 的实测结果决定。**

### 5.1 共享阶段：TwoPuncture 初值求解

| 优先级 | 文件 | 主要作用 | 可关注的优化方向 |
| --- | --- | --- | --- |
| 高 | `src/TwoPunctures.C` | 双黑洞初值求解的主要实现 | 热点循环并行、减少动态分配、复用缓冲区、向量化、数学函数和预条件策略 |
| 中 | `src/TwoPunctureABE.C` | 初值程序入口 | 调用流程、初始化和整体耗时 |

这部分虽然不单独评分，但会分别计入 `TwoPunctureABE + ABE` 和 `TwoPunctureABE + ABEGPU` 的总时间，因此优化一次可以同时帮助 CPU 和 GPU 两项任务。

### 5.2 CPU 演化：ABE

| 优先级 | 文件 | 主要作用 | 可关注的优化方向 |
| --- | --- | --- | --- |
| 很高 | `src/bssn_rhs.f90` | 计算 BSSN 方程右端项，属于主要规则网格计算 | OpenMP、自动向量化、SIMD、循环与访存优化 |
| 高 | `src/diff_new.f90` | 普通有限差分 | 连续访存、减少重复计算、向量化 |
| 高 | `src/lopsidediff.f90` | 偏置有限差分 | 循环、访存和 SIMD 优化 |
| 高 | `src/kodiss.f90` | Kreiss-Oliger 数值耗散，用于稳定演化 | 并行、向量化和 stencil 访存优化 |
| 高 | `src/rungekutta4_rout.f90` | Runge-Kutta 时间更新 | 合并循环、OpenMP、向量化 |
| 高 | `src/prolongrestrict_cell.f90` | 粗细网格之间的插值和限制操作 | 数据局部性、并行粒度、减少重复访问 |
| 高 | `src/Parallel.C` | MPI 通信和进程协作 | 合并小消息、减少同步、通信计算重叠、负载均衡 |
| 高 | `src/MPatch.C` | Patch 管理和 ghost zone 等操作 | Patch 并行、数据布局、通信和拷贝开销 |
| 中 | `src/bssn_class.C` | CPU 演化的上层组织与调用 | 查找 kernel 调用、同步和不必要的临时操作 |
| 中 | `src/Block.C`、`src/cgh.C` | 网格块及层级管理 | block/level 级并行和负载划分 |

CPU baseline 已经使用 MPI，但没有真正的 OpenMP 并行区域。加入 OpenMP 时，除了修改循环，还要在 `CMakeLists.txt` 中启用 OpenMP，并重新测试 MPI rank 数与每个 rank 的线程数。线程越多不一定越快，因为还会受到 NUMA、缓存、通信、同步和负载不均衡的影响。

### 5.3 GPU 演化：ABEGPU

| 优先级 | 文件 | 主要作用 | 可关注的优化方向 |
| --- | --- | --- | --- |
| 很高 | `src/bssn_rhs_gpu.cu` | GPU 上计算 BSSN RHS 的大型核心 kernel | block 大小、寄存器压力、occupancy、访存、kernel 拆分或融合 |
| 很高 | `src/bssn_step_gpu.C` | host 侧组织 GPU 演化和 Runge-Kutta 子步 | 减少 launch 和同步、跨变量批处理、stream 与依赖管理 |
| 高 | `src/diff_new_gpu.cu` | GPU 普通有限差分 | 合并访存、邻域数据复用、shared memory 是否真正有效 |
| 高 | `src/lopsidediff_gpu.cu` | GPU 偏置有限差分 | 分支、访存和线程映射 |
| 高 | `src/kodiss_gpu.cu` | GPU 数值耗散 | stencil 访存、缓存、线程块形状 |
| 高 | `src/rungekutta4_rout_gpu.cu` | GPU Runge-Kutta 更新 | 对多个变量进行 batching，减少大量小 kernel launch |
| 高 | `src/prolongrestrict_cell_gpu.cu` | GPU 粗细网格插值和限制 | 非连续访存、并行粒度、数据布局 |
| 高 | `src/MPatch_gpu.cu` | GPU Patch 和数据打包相关操作 | host/device 拷贝、打包、显存管理 |
| 高 | `src/Parallel_GPU.cpp` | GPU 与 MPI 通信相关逻辑 | host staging、同步、CUDA-aware MPI 可行性 |
| 高 | `src/gpu_manager.cu` | GPU 内存和设备资源管理 | 避免频繁分配释放、复用显存、减少同步 |
| 中 | `src/bssn_gpu_class.C` | GPU 演化上层组织 | 数据生命周期、host/device 数据流 |
| 中 | `src/surface_integral_gpu.cu`、`src/getnp4_gpu.cu`、`src/fadmquantites_bssn_gpu.cu` | ADM 量、引力波等分析计算 | 分析 kernel 的并行、访存以及与主演化的重叠 |

GPU 优化不能只看 kernel 执行时间，还要同时检查：

- kernel 发射次数是否过多；
- host 到 device、device 到 host 的数据搬运是否频繁；
- 是否有不必要的 `cudaDeviceSynchronize()`；
- 线程是否发生分支发散；
- 寄存器使用是否导致 occupancy 太低；
- global memory 访问是否连续合并；
- shared memory 带来的同步、占用和 bank conflict 是否抵消收益；
- 单个 A100 MIG 上启动多个 MPI rank 是否造成 GPU 争用。

## 6. 推荐的优化顺序

1. 先用原始版本完整运行一次，记录 `This Program Cost` 和正确性结果；
2. 对完整程序做 profiling，确认时间主要花在初值、CPU/GPU kernel、MPI、数据搬运还是 I/O；
3. 先修改占比最大的热点，不要仅凭文件名猜测；
4. 每次只做一个容易解释的改动，并记录前后性能指标；
5. 运行 `./check.sh`，确认结果仍符合允许误差；
6. 最后再调整编译器、MPI/OpenMP 组合、绑核及 NUMA 配置；
7. 用正式输入重新进行端到端计时和正确性检查。

CPU 建议使用 `perf` 定位热点；GPU 程序可用 Nsight Systems 看 CPU、MPI、CUDA 和数据传输的时间线，再用 Nsight Compute 分析最耗时的 kernel。VTune 可帮助观察 GPU 程序的主机端调用链和等待。

## 7. 哪些事情不能作为优化手段？

正式评测要求数学问题和必要计算保持不变，因此不能：

- 缩小网格或降低网格层级；
- 缩短正式演化时间；
- 减少物理计算或跳过必要输出；
- 修改黑洞质量、位置、动量等评测输入；
- 直接读取预计算答案；
- 简单地把关键计算换成低精度以换取速度；
- 只报告某个局部 kernel 的加速，而不检查端到端时间和结果。

调试时可以临时缩短演化时间来快速验证代码，但正式测试前必须恢复规定输入。`AMSS_NCKU_Input.py` 在正式测试中只允许调整 MPI、OpenMP 和 GPU 运行相关参数。

## 8. 输出结果怎么看？

默认结果位于：

```text
GW250118/AMSS_NCKU_output/
GW250118/AMSS_NCKU_output/binary_output/
GW250118/figure/
```

主要结果文件如下：

| 文件 | 含义 |
| --- | --- |
| `bssn_BH.dat` | 两个黑洞的位置和轨迹信息 |
| `bssn_ADMQs.dat` | ADM 质量、动量和角动量等物理量 |
| `bssn_psi4.dat` | 用于提取引力波的 Weyl 标量 `Psi4` |
| `bssn_constraint.dat` | 数值解对约束方程的满足程度，可用来观察误差 |
| `Error.log` | 运行日志及错误信息 |

图片适合快速观察明显错误，但最终应以数值文件和 `./check.sh` 的比较结果为准。

## 9. 最后总结

这个实验不是“把某个循环改成 CUDA”这么简单，而是一次完整的科学计算程序优化：

- `TwoPunctureABE` 生成双黑洞初值；
- `ABE` 或 `ABEGPU` 执行 BSSN 时间演化；
- MPI、OpenMP、CUDA 和 AMR 共同决定计算与通信效率；
- 最重要的 CPU 阅读入口是 `bssn_rhs.f90`、差分/RK/网格插值 kernel，以及 `Parallel.C`、`MPatch.C`；
- 最重要的 GPU 阅读入口是 `bssn_rhs_gpu.cu`、`bssn_step_gpu.C`、各类 `*_gpu.cu` kernel，以及 GPU/MPI 数据管理文件；
- 任何优化都必须同时满足：**结果正确、端到端确实变快、原因可以用 profiling 数据解释。**

一、 五大核心功能模块拆解
1. 程序的“大脑与骨架”：高层控制与网格管理 (C++)这部分代码负责分配内存、管理多层级自适应网格（AMR），但不参与具体的物理公式计算。
- ABE.C：CPU 演化程序的主入口（main 函数所在），负责串联起整个生命周期。
- TwoPunctureABE.C：初值生成程序的主入口。
cgh.C / cgh.h：网格层级管理器（Cartesian Grid Hierarchy），统筹所有的粗细网格层。
- MPatch.C / MPatch.h：网格块（Patch）类，管理单个 MPI 进程分配到的三维数组数据。
- var.C / var.h：物理变量的注册与管理。
2. 程序的“神经系统”：并行与通信 (C++)负责在多核/多节点之间传递数据，解决边界重叠问题。
- Parallel.C / Parallel.h：MPI 通信核心。负责在不同 MPI 进程间打包、发送、接收、解包 Ghost Zone（边界虚点）数据。（注意：之前日志中发现的负载不均问题，根源就在这里的网格分配逻辑）。-
- Parallel_GPU.cpp：GPU 版本的 MPI 通信实现（涉及 GPU-Aware MPI 或内存显存拷贝）。
3. 程序的“发动机”：核心物理与数学算子 (Fortran / CUDA)这是极其密集的浮点运算区域，你进行性能优化（加 OpenMP、SIMD、调整显存访存）的绝对主战场。
- bssn_rhs.f90 / bssn_rhs_gpu.cu：最核心文件！计算 BSSN 方程的右端项（时空演化的核心物理公式），占总计算时间的 50% 以上。
- diff_new.f90 / lopsidediff.f90：计算三维空间中的一阶、二阶有限差分。
- rungekutta4_rout.f90：4 阶龙格-库塔时间积分算法，负责把计算出的时间导数更新到下一时刻。
- kodiss.f90：计算 Kreiss-Oliger 人工耗散，用于消除数值高频震荡。
- prolongrestrict_cell.f90：AMR 网格插值（粗网格算细网格）与投影（细网格更新粗网格）。
4. 宇宙的“创世大爆炸”：初值生成 (C++ / Fortran)在时间开始前，设定两个黑洞的初始状态。
- TwoPunctures.C / Ansorg.C：基于谱方法求解黑洞初值的逻辑。
- initial_puncture.f90：将解出的初值映射到三维演化网格上。
5. 质检与监视器：物理分析与输出 (C++ / Fortran)
- fadmquantites_bssn.f90：计算 ADM 质量、动量等守恒量（用于检查精度是否符合 Ham <= 2.0 的约束）。
- getnp4.f90 / surface_integral.C：计算并提取引力波波形（$\Psi_4$ 标量）。
- monitor.C / perf.C：打印日志、记录各模块的运行耗时。

二、 程序的执行调用顺序 (Call Sequence)
当你运行 ./run.sh 启动 ./ABE 时，程序的生命周期严格按照以下四步流水线执行：
>- 阶段 1：初始化与网格铺设 (Initialization)ABE.C 启动，调用 MPI 初始化。读取 AMSS_NCKU_Input.py 传入的参数。cgh.C 与 MPatch.C 在内存中建立多层三维网格数组，Parallel.C 将这些网格块切分并派发给各个 MPI 进程。
>- 阶段 2：注入初值 (Initial Data)程序读取 Ansorg.psid（由 TwoPunctureABE 提前算好的数据），通过 initial_puncture.f90 将双黑洞的时空弯曲数据铺设到刚才建立好的网格上。
>- 阶段 3：核心时间演化循环 (The Main Evolution Loop) —— 极度耗时！进入主循环（t = 0 到 t = 40.0），每前进一步，都会触发 **rungekutta4_rout.f90** 。在 RK4 的每一个子步中，发生如下调用链：
>- 通信同步：C++ 侧调用 **Parallel.C**，各个进程互相交换边界虚点（Ghost Zone）数据。
>- 算子计算：C++ 把三维数组指针丢给 Fortran。求空间导数：Fortran 调用 **diff_new.f90**，算出各方向的差分。
>- 算物理方程：Fortran 调用最耗时的 **bssn_rhs.f90**，算出各变量的时间演化率（右端项）。
>- 加人工耗散：调用 **kodiss.f90** 过滤高频噪声。
>- 层级间同步：调用 **prolongrestrict_cell.f90** 让粗细网格的数据保持一致。(上述 1~6 步在极其庞大的三维循环中反复执行，构成了你看到的 3000 多秒的总耗时。)
- 阶段 4：数据落盘与后处理 (Output)每隔一定时间步，ABE.C 会调用 **fadmquantites_bssn.f90** 检查精度约束。调用 **checkpoint.C** 将当前黑洞坐标、引力波数据写入二进制 .dat 文件。达到 Final_Evolution_Time 后，程序安全退出。
