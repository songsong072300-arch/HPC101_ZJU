### 性能优化的好伙伴：Profiler 工具

!!! warning "容器内的 VTune Profiler 使用限制"

    - **能用的**：`vtune -collect hotspots`（软件采样）。能看到热点函数、调用栈等，本节的流程围绕它展开。
    - **不能用的😭**：依赖硬件事件采样的分析类型（Microarchitecture Exploration、Memory Access、`-knob sampling-mode=hw` 等）。
        - 替代：微架构层面的指标（Top-down、IPC）用 `perf stat` 。

!!! tip
    集群新版镜像 `devbox:4` (老容器需升级) 已预装 VTune 与 perf。若在脚本等非登录 shell 中找不到 `vtune`，可先 `source /etc/profile.d/vtune.sh`。

第一次使用 VTune 时，可以先阅读 Intel 官方的
[Linux 性能分析快速入门](https://www.intel.com/content/www/us/en/docs/vtune-profiler/tutorial-common-bottlenecks-linux/2025-0/overview.html)，
跟随示例了解一次完整的“采样—定位—分析”流程。

集群不提供图形桌面，可以采用“**集群命令行采样，本地 GUI 分析**”的方式。~~（当然你也可以在容器里安装图形界面, 这或许更加方便）~~
在实验目录中执行例如：

```bash
vtune -collect hotspots -result-dir vtune-hotspots -- \
  ./build/lab2 128 256 128 16 4 2000 --benchmark
```

`--benchmark` 让 driver 跳过基线循环、只跑 `preprocess` 和你的优化实现（正确性检查保留）。
profiling 时都应带上它：否则统计里混着基线循环，而且你的实现越快，基线的占比反而越大。

采样结束后，在本地终端下载**完整的结果目录**（不要只复制其中的 `.vtune` 文件）。为了正常查看
源码和汇编，建议同时下载采样时使用的可执行文件,示例命令如下：

```bash
scp -r <username>@<cluster>:<path-to-repo>/lab2/vtune-hotspots .
scp <username>@<cluster>:<path-to-repo>/lab2/build/lab2 .
```

随后在本地启动 VTune Profiler GUI，具体安装路径选择 **Open > Result...**，打开结果目录中的 `.vtune` 文件。
如果源码或汇编视图无法正确显示，请确认本地保留了与采样时一致的源码和可执行文件，并在
**Binary/Symbol Search** 中补充相应路径。

开始优化时，不必急于逐个尝试各种优化技巧，可以先使用性能采样工具定位瓶颈，再提出并验证优化假设，
通常会更有效。（除了更快的定位瓶颈之外，一个你做的代码改动不论是正优化还是负优化，有一个可解释的指标会给你在优化过程中较强的正反馈，同时也不会让你陷入对着代码穷举各种优化方式的那种“炼丹”的痛苦。 ~~或许结合ai还会有更加奇妙的火花？~~ 如果你是想认真学习并实践体系结构知识的人这块可以让你学爽，~~可解释性一直都是很美妙的不是吗~~）
在 Intel CPU 上，可以把 VTune 与 perf 组合起来，大致按下面的顺序使用：（注意以下有很多体系结构的专有名词，在没上过专业课的情况下要理解它们确实会比较痛苦，但是结合ai可以较快的帮你搞懂它们意思，最后构建起一个现代处理器的抽象模型, 这样之后就会顺畅许多）

1. **先找热点。** 使用 **Hotspots**（热点分析：按采样结果找出最耗时的代码）查看 Bottom-up
    （从最耗时的函数向上追溯调用者）、调用栈和源码视图，确认端到端时间主要花在了哪些阶段。~~(但是其实这个程序你一眼就可以看懂， 你也可以马上定位到瓶颈在哪，所以这一步在这一个lab当中其实不那么重要)~~
   以参考实现为例，热点几乎全部落在 `expert_ffn` 上，行级视图会进一步把时间归到 gate/up/down 三条 int8 内积循环，而后面所有向量化的功夫都花在这几行上。
2. **再解释热点。** 可以先把 CPU 流水线粗略分成前端和后端：前端负责取出并解码指令，再把工作交给
    后端；后端等待操作数就绪，调用执行单元完成计算并提交结果。VTune 中做这件事的分析类型是 **Microarchitecture Exploration**，但它依赖的
    硬件事件采样在容器内不可用；好在 perf 内建了同一套 **Top-down** 方法：

    ```bash
    perf stat --topdown -- ./build/lab2 128 256 128 16 4 60 --benchmark
    perf stat --topdown --td-level 2 -- ./build/lab2 128 256 128 16 4 60 --benchmark
    ```

    Top-down 会把流水线中的工作分成四类：
    **Front-End Bound**（前端受限：取指、解码或供给指令的速度跟不上），**Bad Speculation**
    （错误推测：分支预测错误等原因使已经执行的工作被丢弃），**Back-End Bound**（后端受限：执行资源
    忙碌或所需数据尚未到达），以及 **Retiring**（有效退休：指令完成并提交了有效结果，占比高通常是
    好现象，但不等于已经达到峰值）。可配合 [Intel 官方中文 Top-down 图解](https://www.intel.cn/content/www/cn/zh/docs/vtune-profiler/cookbook/2023-0/top-down-microarchitecture-analysis-method.html) 继续阅读。

    **Back-End Bound** 较高时，`--td-level 2` 可以进一步区分 **Core Bound**（核心执行资源受限，例如执行端口争用或
    较长的数据依赖链）和 **Memory Bound**（内存层次受限，执行单元在等待数据）。内存层次由近到远
    包括 **L1D**（每个核心最近、容量最小的一级数据缓存）、**L2**（容量更大但稍慢的二级缓存）、
    **LLC**（Last-Level Cache，通常由多个核心共享的末级缓存；本平台上是 L3）和 **DRAM**
    （主内存，容量最大但访问延迟显著高于缓存）。这些 Bound 指标表示停顿主要与哪个层级相关，
    并不自动意味着该层带宽已经打满，具体含义可参看 [VTune Memory Access 指标说明](https://www.intel.com/content/www/us/en/docs/vtune-profiler/user-guide/2024-0/memory-access-analysis.html)。

    以初始框架 S3 为例进行测试：Retiring 75%、Back-End Bound 20%
    （其中 Core Bound 20%、Memory Bound 仅 0.4%）、Front-End Bound 3.5%、Bad Speculation 0.8%，IPC ≈ 4.7。Memory Bound 几乎为零，说明参考实现**并不卡访存**；IPC 高达 4.7，流水线也没有空转——它只是在高效地执行海量标量指令，
    每条指令只完成一次 8-bit 乘加。瓶颈是**指令总数**本身，所以优化方向是提高单条指令完成的工作量。向量化生效后再测一次，你会看到 Retiring 下降、Memory Bound 上升，也就是瓶颈发生了变化。
    另外注意 `perf stat` 统计的是**整个进程**，所以同样要带上 `--benchmark`。

3. **检查并行效率。** 对多线程实现，把 hotspots 结果按线程分组即可看出负载是否均衡，报告中的
    **Spin Time** 列直接给出各线程忙等的时间；再对比墙钟时间与 CPU 总时间，可以估算并行效率。
    需要警惕的问题包括：串行区、负载不均、spin/wait（忙等或阻塞等待）、同步竞争、伪共享
    （线程修改同一缓存行中的不同数据，仍引发缓存行来回迁移）、缓存行争用（多个核心争抢同一缓存行
    的所有权）以及 NUMA（非一致内存访问：访问其他 CPU 节点的内存通常更慢）。

采样时应让被测部分运行时间足够长(目前的程序运行一次的时间很短，但是vtune运行的方式是随机的对运行时程序取快照, 并通过采样的时候运行所在函数来粗略的估计不同函数的运行时间占比, 所以为了能够采准要么让采样频率高一点，要么就运行的次数多一点, 后者相对更加方便一点), 并保持输入、线程数和绑核方式一致。Profiler 用于定位和解释瓶颈，最终性能仍应以实验规定的 driver 计时结果为准。更详细的操作可参考 Intel 官方的 [Hotspots 使用指南](https://www.intel.com/content/www/us/en/docs/vtune-profiler/user-guide/2025-4/basic-hotspots-analysis.html)，更深入的分析方法与常见案例可查阅 [VTune Performance Analysis Cookbook](https://www.intel.com/content/www/us/en/docs/vtune-profiler/cookbook/2025-4/overview.html)。

!!! tip "优化后期：评估剩余优化空间"

    当主要热点已经稳定后，建议为热点建立一份简要的性能上限分析。首先估算运算量、数据搬运量和算术
    强度，再借助**Roofline**（屋顶线模型：将程序性能与计算、带宽上限放在同一张图中；参见 [Intel Roofline 简介](https://www.intel.com/content/www/us/en/developer/articles/guide/intel-advisor-roofline.html)），
    判断当前实现更接近计算上限，还是 L1D、L2、LLC 或 DRAM 中某一级的带宽上限。比较时应保持工作负载、
    线程数和绑核方式一致。

    分析 CPU 流水线时，可以同时记录**IPC**（Instructions Per Cycle，平均每周期退休的指令数）、
    Front-End Bound、Core Bound、处理器频率和有效操作吞吐（每秒实际完成的 MAC 或其他目标运算数）。
    这些指标分别反映指令推进效率、前端供给情况和核心执行资源的利用情况，需要结合热点代码一起解释。
    对多线程实现，还应绘制线程数与加速比的关系，并检查核心利用率、串行区、同步等待、负载不均、缓存
    一致性开销、NUMA 访问和全核运行时的频率变化。分析的目标是解释当前性能与硬件上限之间的差距，
    并据此选择下一步优化对象，而不是单独追求某一项指标。（~~ai或许比我们更擅长做这种迭代优化，但是一下找到应该优化的点的直觉或许是ai所没有的, 优化过程中就可以积累这个直觉~~）
