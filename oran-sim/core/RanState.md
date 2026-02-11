## 2026/02/10 RanStateBus

"能被观测、能被用来做算法"的量。

一、时间相关状态（Time）

这些量用于对齐调度周期和事件顺序。

time.slot
当前仿真 slot 编号

time.t_s
当前仿真时间（秒）

用途：

对齐 near-RT tick

计算 KPI 随时间变化

二、拓扑信息（Topology）

这些量描述网络结构，通常是慢变或不变的。

topology.numCell
小区数量

topology.numUE
UE 数量

topology.gNBPos
gNB 位置坐标

用途：

小区级决策

移动性相关算法

三、UE 级无线状态（UE Radio State）

这是 MAC / RRM xApp 最核心的输入。

1️⃣ 位置与关联

ue.pos
UE 位置

ue.servingCell
UE 当前服务小区

用途：

切换

负载感知

2️⃣ 无线测量

ue.rsrp_dBm
UE 对所有小区的 RSRP

ue.sinr_dB
UE 在服务小区的 SINR

ue.cqi
UE CQI（由 SINR 映射）

ue.mcs
UE 实际或近似使用的 MCS

ue.bler
UE 最近一次调度的 BLER

用途：

调度

波束

功控

异常检测

四、UE 级队列与业务状态（Traffic / QoS）

这是 URLLC / QoS xApp 的核心输入。

ue.buffer_bits
UE 当前排队数据量

ue.urgent_pkts
UE 紧急包数量（如 deadline ≤ 阈值）

ue.minDeadline_slot
UE 当前最小包截止时间（slot）

用途：

URLLC 调度

Deadline 感知控制

丢包预测

五、小区级资源状态（Cell Resource State）

这些量用于负载与能效相关 xApp。

cell.prbTotal
每小区可用 PRB 总数

cell.prbUsed
当前 slot 已使用 PRB

cell.prbUtil
PRB 利用率

cell.txPower_dBm
小区发射功率

cell.energy_J
累计能耗

cell.sleepState
小区休眠状态

用途：

负载均衡

能耗优化

频谱共享

六、事件与告警（Events）

这些量用于异常检测与策略触发。

1️⃣ 切换事件

events.handover.countTotal
累计切换次数

events.handover.lastUE
最近一次切换 UE

events.handover.lastFrom
源小区

events.handover.lastTo
目标小区

用途：

Mobility xApp

切换优化

2️⃣ 异常事件（预留）

events.anomaly.flag
是否检测到异常

events.anomaly.type
异常类型

events.anomaly.severity
严重程度

events.anomaly.ueId / cellId
关联对象

用途：

异常检测 xApp

non-RT 触发策略

七、KPI 汇总状态（KPI）

这些量通常用于 non-RT 或 near-RT 的慢决策。

kpi.throughputBitPerUE
UE 累计吞吐

kpi.dropTotal
总丢包数

kpi.dropURLLC
URLLC 丢包数

kpi.handoverCount
切换次数

kpi.energyJPerCell
小区能耗

kpi.prbUtilPerCell
平均 PRB 利用率

用途：

rApp 输入

策略切换

性能评估