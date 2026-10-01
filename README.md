# UERANSIM-N2handover

在 [UERANSIM](https://github.com/aligungr/UERANSIM) **v3.3.0** 上以**补丁**形式实现的 **N2 切换（NG-RAN 间 N2-based Handover）仿真**功能：由 `nr-cli` 触发，源 gNB 经 N2（NGAP）向 5GC 发起切换，目标 gNB 分配资源，UE 完成"空口"重配并迁移，5GC 完成路径切换与源侧释放。

参考规范：TS 23.502 §4.9.1.3（Preparation/Execution）、TS 38.413 §8.4（Handover Preparation / Resource Allocation / Notification）、TS 23.501、TS 38.300。

## 特性

- **CLI 触发**：源 gNB 上 `nr-cli` 执行 `handover <ue-id> <target-gnb-id>`，源 gNB 发送 NGAP **Handover Required**（HandoverType=intra5gs、TargetID=目标 gNB 全局 ID+TAI、PDU 会话列表、Source-To-Target 透明容器、UE 历史信息）
- **准备阶段完整**：目标 gNB 收到 **Handover Request** 后逐 PDU 会话分配下行 N3 端点（TEID），返回 **Handover Request Acknowledge**（Admitted/Failed 列表、Target-To-Source 透明容器）；全部会话被拒时返回 **Handover Failure**
- **执行阶段完整**：源 gNB 收到 **Handover Command** 后向 UE 下发 RRC Reconfiguration（承载切换命令）；UE 按 **NCI** 解析目标小区并迁移（保持 RRC_CONNECTED），向目标 gNB 发送 RRC Reconfiguration Complete；目标 gNB 发送 **Handover Notify**；5GC 完成下行路径切换后源 gNB 收到 **UE Context Release Command** 并释放
- **UE 侧 NAS**：切换后若 TAI 变化，按 TS 23.502 §4.9.1.3.3 步骤 12 触发**移动性注册更新**（默认配置两个 gNB 同 TAC，不触发；跨 TAC 场景需将目标 TAC 纳入 AMF 支持列表，属扩展用法，未做端到端验证）
- **失败与异常**：Handover Preparation Failure 记录原因；目标侧 pending 切换超时自动清理；目标 gNB 部分会话失败时按规范返回 Failed 列表
- **可重复切换**：支持 gNB1 ⇄ gNB2 反复切换（陈旧 UE 上下文、GTP DL TEID 替换均处理）
- **仿真身份设计**：以 RLS **STI**（UE 的"空口"稳定标识）跨 gNB 标识 UE，以 **NCI** 让 UE 定位目标小区——不依赖节点顺序/ID 巧合（修复了社区 PR 方案中的脆弱假设）
- **确定性小区选择**：同信号强度时按较小 NCI 择先，保证初始驻留与切换演示可复现
- **基础数据面**：UL 在 UE 迁移后立即经目标 gNB（NL 转 N3）；DL 在 5GC 路径切换后恢复。**不实现** gNB 间转发隧道（见"简化点"）
- **结构化事件日志**：每个 gNB 写 `logs/<gnb-name>.ho-events.jsonl`（JSONL；`ho_id` 贯通源/目标、阶段枚举、单调/挂钟时间戳），零新增配置项、服务无关；配套 `deploy/ho-batch.sh` 批量往返驱动
- **单元测试**：`ctest` 覆盖透明容器编解码（边界/非法输入）、确定性小区排序、目标小区解析、事件序列化
- **与 ueransim-ims 补丁共存**：两种 apply 顺序均可干净应用，编译通过，双测试套件（`ims-tests` + `ho-tests`）全绿

## 与 3GPP 流程的对应

```
 UE            S-NG-RAN(源)              AMF           SMF        T-NG-RAN(目标)
  |                 |                    |              |              |
  |   (CLI 触发, 代替 Measurement Report) |              |              |
  |                 |--Handover Required->|              |              |
  |                 |   TargetID, PDU 会话列表,           |              |
  |                 |   Source-To-Target 容器             |              |
  |                 |                    |--UpdateSMContext(每会话)---->|
  |                 |                    |              |              |
  |                 |                    |----Handover Request--------->|
  |                 |                    |              |   分配 DL TEID |
  |                 |                    |<---Handover Request Ack ------|
  |                 |<--Handover Command--|              |              |
  |<--RRC Reconf.---|                    |              |              |
  |   (UE 迁移: NCI 解析 + 切换服务小区)  |              |              |
  |-------------------------------------- RRC Reconf. Complete -------->|
  |                 |                    |<---------Handover Notify -----|
  |                 |                    |--UpdateSMContext(HO Complete)->|
  |                 |                    |              |  下行路径切换 |
  |<=================== 数据面：UL 经目标 / DL 随路径切换 =============>|
  |                 |<--UE Context Release|              |              |
  |                 |---Release Complete->|              |              |
```

## 交付包结构

```
ueransim-N2handover/
├── README.md                    本文件
├── LICENSE                      UERANSIM 原始许可证（GPL-3.0）
├── patch/
│   └── n2handover.patch         面向 UERANSIM v3.3.0 的完整补丁
├── config/
│   ├── gnb1.yaml                源 gNB 配置模板（free5GC compose 拓扑）
│   ├── gnb2.yaml                目标 gNB 配置模板
│   └── ue.yaml                  UE 配置模板（gnbSearchList 含两个 gNB）
├── deploy/
│   ├── docker-compose.n2handover.yaml   free5GC compose 的 gNB/UE override（含事件目录挂载）
│   ├── provision-subscriber.sh          通过 WebUI API 开通订阅者
│   ├── run-handover.sh                  触发切换并打印两侧结果
│   ├── ho-batch.sh                      批量切换驱动（N 次 / 往返 / 参数化）
│   ├── open5gs/                         docker_open5gs（VoNR）测试床 + IMS 通话中切换验收
│   │   ├── README.md                    测试床部署/开户/验收步骤与排错
│   │   ├── docker-compose.ueransim.yaml UERANSIM 侧 compose override
│   │   ├── gnb1|gnb2|ue1|ue2.yaml       两 gNB 两 UE 配置（双 PDU 会话 + IMS）
│   │   ├── provision.sh                 Open5GS + pyHSS 开户
│   │   ├── run-ims-test.sh              一键验收（通话 + N 次往返切换 + RTP 缺口 + 控制面耗时 + 事件相关性）
│   │   ├── tweaks/apply-open5gs-tweaks.sh  测试床环境适配（3 处，幂等）
│   │   └── evidence/ims-handover-summary.txt  实测证据摘要
│   └── free5gc-ims/                     free5GC + IMS 测试床（方案 L）与双核对比
│       ├── README.md                    部署/开户/验收步骤、排错（NSSF/重复会话/NAT 抓包）
│       ├── docker-compose.ueransim.yaml UERANSIM 侧 overlay（两 gNB 两 UE）
│       ├── docker-compose.ims.yaml      IMS 8 服务（接入 free5GC 网络）
│       ├── gnb1|gnb2|ue1|ue2.yaml       free5GC 版配置（PLMN 001/01、双会话、ePCO+静态兜底）
│       ├── env.free5gc                  IMS 侧 .env（free5GC 网络参数）
│       ├── provision-free5gc-ims.sh     开户（WebUI 含 ims/SmPolicyData + pyHSS）
│       ├── tweaks/apply-free5gc-ims-tweaks.sh  幂等适配（free5GC 侧 + IMS 侧 N5 关闭）
│       └── evidence/                    实测证据（汇总/CSV/压缩抓包/双核对比）
└── docs/
    ├── ARCHITECTURE.md          实现架构、仿真身份设计、与规范的对应与简化点
    ├── BUILD.md                 构建（含与 ueransim-ims 补丁共存的验证）
    ├── RUN.md                   端到端运行（free5GC/Open5GS）、触发切换、验证与排错
    ├── MEASUREMENT.md           事件日志 schema、批量驱动、IMS 连续性取证方法
    └── REGRESSION.md            本地回归测试记录（含基线对照实验）
```

## 快速开始

```bash
# 1) 拉取 UERANSIM v3.3.0 基线并应用补丁
git clone https://github.com/aligungr/UERANSIM && cd UERANSIM
git checkout v3.3.0
git apply <path-to>/ueransim-N2handover/patch/n2handover.patch

# 2) 构建（依赖 cmake>=3.17, g++>=11, libsctp-dev）
mkdir build && cd build && cmake .. && make -j$(nproc)

# 3) 运行单元测试
ctest --output-on-failure

# 4) 端到端：见 docs/RUN.md（两个 nr-gnb + 一个 nr-ue + 5GC）
```

## 状态与验证

| 项目 | 状态 |
|---|---|
| 补丁独立应用（v3.3.0） | ✅ 已验证（宿主机原生 + Docker 两种构建方式） |
| 与 `ueransim-ims/patch/ims.patch` 共存（两种顺序） | ✅ 已验证（原生与 Docker 均为：apply + 编译 + 2/2 测试） |
| 单元测试（`ho-tests`） | ✅ 23 项通过（含转发缓冲 9 项） |
| 端到端（free5GC v4.2.3 compose，双 gNB + UE，**交付包文件原样**） | ✅ 已验证：多次切换（含反向），单次全过程约 27 ms；切换前后 ping 0% 丢包；`tcpdump` 证实切换后 GTP 仅经目标 gNB。详见 `docs/RUN.md` §9 |
| **本地回归测试**（多 UE、多 PDU 会话、失败路径、基线对照） | ✅ 全部通过，未引入回归；详见 `docs/REGRESSION.md` |
| 结构化事件日志 + 批量驱动 | ✅ free5GC 实测（3 次往返切换，`ho_id` 两侧一致、宿主机可见 JSONL）；详见 `docs/MEASUREMENT.md` |
| **Open5GS 兼容性**（docker_open5gs `sa-vonr-deploy`，双 gNB + 双 UE） | ✅ 已验证：接入/双 PDU 会话/反复 N2 切换正常；详见 `docs/RUN.md` §10 |
| **IMS 通话中切换验收**（VoNR，下游场景） | ✅ 已验证：通话经 gNB1→gNB2→gNB1 两次切换保持 CONFIRMED；RTP 最大间隔 39.8–40.9 ms、>60 ms 中断 0；证据 `deploy/open5gs/evidence/` |
| **free5GC + IMS 验收**（方案 L；与 Open5GS 同协议对比） | ✅ 已验证：10 次往返（20 次切换）通话保持 CONFIRMED；RTP 最大间隔 ~41 ms、>60 ms 中断 0；**SMS 双向收发**（TS 24.341，`delivered (202)` + 对端收到）；双核控制面时序差异已记录；证据 `deploy/free5gc-ims/evidence/`；详见 `docs/RUN.md` §11 |
| **数据转发（v2，2026-10-01）** | ✅ 已验证：free5GC/Open5GS 各 10 次往返（20 次切换）通话保持 CONFIRMED；UE 侧 `mediaTx/mediaRx` 差 0–3 包、RTP >60 ms 中断 0；源侧每切换转发 9–11 个 IMS 媒体包；证据 `deploy/*/evidence/*v2-forwarding*`；详见 `docs/RUN.md` §12 |
| **标准对齐（v2.1，2026-10-01）** | ✅ C1 per-flow `dataForwardingAccepted`、C2 尊重 `DataForwardingNotPossible`、C3 End Marker 转发/接收、C4 失败会话列表；free5GC 20 次切换复验（计数差 1 包、>60 ms 中断 0、end marker 20/20、无未处理 GTP）+ 两 UE 并发切换隔离验证；证据 `deploy/free5gc-ims/evidence/*v21*` |

## 简化点（重要）

UERANSIM 仿真"空口"，因此以下内容按仿真方式实现或有意省略（详见 `docs/ARCHITECTURE.md` 第 6 节）：

- 透明容器内的 RRC 载荷为**仿真自定义格式**（标准 NGAP 信封不变）；无 AS 安全
- **已实现 gNB 间数据转发**（v2，2026-10-01）：源侧重定向 + 目标侧接收/缓存/会话寿命别名；直连与间接两种核心网口味统一处理；转发封装按隧道方向携带 UL 变体 PDU Session Container（QFI）
- **不做** RAN Status Transfer / PDCP SN 保持、DAPS、Handover Cancel、AMF 重定位
- 触发方式为 CLI（代替测量报告）；目标小区 NCI 由目标 gNB ID 按约定推导
