# 控制参数与KPI观察表（简洁版）

> 说明：表格记录“已验证链路合理”的控制参数与其主要KPI影响方向。
> 观察参数指实验中实际关注的量；控制参数指可调的网络控制变量。

## 1. 观察参数（Observations）
| 观察参数 | 含义 | 备注 |
|---|---|---|
| MeanSINR / p10/p50/p90 SINR | SINR均值与分位 | 用于解释可靠性与吞吐变化 |
| BLER | 块错误率 | 可靠性核心指标 |
| DropRatio | 丢包率 | 可靠性核心指标 |
| Throughput (Mbps) | 总吞吐 | 容量指标 |
| PRButil | 资源利用率 | 饱和/负载程度 |
| CongIdx | 拥塞指数 | 综合负载+链路 |
| Bit/J | 能效 | 能耗相关 |
| Fairness (Jain) | 公平性 | 结构性指标 |
| Top10Share | Top-10%吞吐占比 | 结构性指标 |
| HOcnt / RLFcnt | 切换/链路失效 | 稳定性 |

## 2. 网络控制参数（已验证合理链路）

| 控制参数 | 影响的主要KPI | 方向性总结 |
|---|---|---|
| `radio.txPowerOffset_dB` | SINR, BLER, Throughput, Energy | 功率↑ → SINR↑, BLER↓, 吞吐↑, 能耗↑ |
| `radio.bandwidthScale` | Throughput, DropRatio | 带宽↑ → 吞吐↑, drop↓ |
| `sleep.cellSleepState` | Throughput, PRButil, DropRatio | 睡眠→吞吐=0, PRB=0, drop=1 |
| `energy.basePowerScale` | Energy, Bit/J | 功耗↑ → bit/J↓, 吞吐基本不变 |
| `radio.interferenceCouplingFactor` | SINR, BLER, Throughput | 干扰↑ → SINR↓, BLER↑, 吞吐略降 |
| `handover.hysteresisOffset_dB` | HOcnt | 滞后↑ → HO次数下降 |
| `handover.tttOffset_slot` | HOcnt, RLFcnt | TTT↑ → HO下降, 极端时RLF上升 |
| `beam.ueBeamId` | SINR, BLER | 固定波束可能偏离最优 → SINR/BLER小幅波动 |
| `beam.mode` (adaptive) | SINR分布, BLER, Throughput | adaptive 提升SINR分布，可靠性改善 |
| `scheduling.selectedUE` (queueMax) | Fairness, Top10, DropRatio | 公平性↑, Top10↓, 可靠性略降（trade-off） |
| `rlf.sinrThresholdOffset_dB` | RLFcnt | 高阈值才触发RLF，呈硬阈值阶跃 |

## 3. KPI 输出建议（针对 QoS/Beam/调度）
- Beam：输出 `p10/p50/p90 SINR` + BLER
- QoS：输出 `qos.dropRatio` 与 `qos.throughput`
- 调度：输出 `Fairness`, `Top10Share`, `SelRate/Valid/NonEmp`
