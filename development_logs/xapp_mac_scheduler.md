# near-RT MAC Scheduler xApp
用来降低 URLLC 丢包率，同时控制对系统吞吐的影响。
在 baseline MAC 调度中：
Round-robin 或 proportional-fair
不显式考虑 packet deadline
URLLC 与 eMBB 共享资源

结果是：
URLLC 包可能排队,
deadline 到期,
即使系统还有资源，也来不及发,
这个问题在 高负载或移动场景 下尤其明显。

期望看到：

对 URLLC:
URLLC drop 明显下降,
尤其在负载高、UE 移动快时

---
这个 xApp 的核心优化目标是：
最小化 URLLC 业务的 deadline violation（drop）

常见的次级目标（不是 MVP 里必须）
1. 维持总体吞吐不显著下降
2. 控制 PRB 利用率
3. 避免单 UE 长期饿死

在你的架构中，xApp 不直接看 PHY/MAC 内部结构，
它只看 near-RT 能拿到的观测（E2 语义）。

典型输入包括：

1️⃣ UE 维度

1. servingCell(u) UE 属于哪个小区
2. buffer_bits(u) UE 是否有 URLLC
3. urgent_pkts(u)（或 min deadline）URLLC 有多急
4. sinr_dB(u) 或 cqi(u) 无线条件好不好

2️⃣ Cell 维度（可选,MVP 里可以不用。）

1. PRB 利用率
2. 小区负载



这个 xApp 的输出非常简单，也非常符合 O-RAN 的设计哲学：

每个小区，选择一个 UE 进行调度, 在你的系统中体现为：
```
action.scheduling.selectedUE(c) = u
```
含义是：

near-RT 建议在 cell c, 当前调度周期, 优先调度 UE u