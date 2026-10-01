# 实现架构（ARCHITECTURE）

本文描述 `n2handover.patch` 的实现结构、仿真特定设计（透明容器、UE 身份）、与 3GPP 流程的对应，以及与 UERANSIM 既有架构（NTS 消息、RLS 空口、GTP 数据面）的衔接方式。

---

## 1. 代码结构与职责

补丁共触及 40 个文件（31 改 + 9 新增）。新增文件：

| 文件 | 职责 |
|---|---|
| `src/lib/ho/ho.hpp/.cpp` | **共享纯函数库**：仿真透明容器编解码（`SourceInfo`/`CommandInfo`）、确定性小区排序（`IsBetterCell`）、按 NCI 解析小区（`FindCellByNci`）。无任务依赖，可单元测试 |
| `src/lib/ho/events.hpp/.cpp` | **切换事件日志**：服务无关的 JSONL 事件写入器（`ho_id` 关联源/目标、单调/挂钟时间戳、失败不影响切换流程）。无任务依赖，可单元测试 |
| `src/gnb/ngap/handover.cpp` | gNB 侧 NGAP 切换过程：`sendHandoverRequired`（源）、`receiveHandoverRequest`（目标，资源分配+回 Ack/Failure）、`receiveHandoverCommand`（源）、`handleHandoverConfirm`、`sendHandoverNotify`、失败/超时清理 |
| `src/gnb/rrc/handover.cpp` | gNB RRC：把切换命令封装为 RRC Reconfiguration 下发；接收 RRC Reconfiguration Complete 并通知 NGAP |
| `src/ue/rrc/handover.cpp` | UE RRC：解析切换命令、按 NCI 解析目标小区、切换服务小区（`ASSIGN_CURRENT_CELL`）、发送 RRC Reconfiguration Complete、通知 NAS |
| `tests/handover/CMakeLists.txt`、`tests/handover/ho_tests.cpp` | 单元测试（14 项） |

主要修改文件：

| 文件 | 修改内容 |
|---|---|
| `CMakeLists.txt` | 追加 `enable_testing()` + `add_subdirectory(tests/handover)`（**置于文件末**，与 ims 补丁的 CMake 改动不冲突） |
| `src/gnb/ngap/{task.hpp,task.cpp,transport.cpp,management.cpp,nas.cpp}` | 切换函数声明/实现接入；NGAP 消息分发（HandoverRequest/Command/PreparationFailure）；HandoverRequest 的 SCTP stream 例外；pending 清理定时器；UE 上下文增加 `sti` |
| `src/gnb/nts.hpp` | 新增 `NmGnbNgapToRrc::HANDOVER`、`NmGnbRrcToNgap::HANDOVER_CONFIRM`；RLS→RRC/NGAP 消息携带 `sti` |
| `src/gnb/rls/*` | 将 RLS STI 从 UDP 任务经控制任务传递到 RRC |
| `src/gnb/rrc/*` | HANDOVER 处理接入、UL DCCH `rrcReconfigurationComplete` 分发、RRC 上下文 `sti` |
| `src/gnb/gtp/task.cpp` | 同名 PDU 会话重复创建时替换 DL TEID（支持反复切换） |
| `src/lib/app/cli_cmd.{hpp,cpp}`、`src/gnb/app/cmd_handler.cpp` | gNB CLI 新增 `handover <ue-id> <target-gnb-id>` |
| `src/ue/nts.hpp`、`src/ue/rrc/*`、`src/ue/nas/mm/*` | UE 侧事件与处理；小区选择排序改为确定性 tie-break；NAS 的 TAI 变化处理 |

---

## 2. 任务内消息流（gNB）

```
[源 gNB]
 appTask(CLI) ──NmGnbCliCommand(HANDOVER)──► 直调 ngapTask->sendHandoverRequired()
 ngapTask ──Handover Required──► sctpTask ──► AMF
 ngapTask ◄──Handover Command── sctpTask
 ngapTask ──NmGnbNgapToRrc(HANDOVER, 容器)──► rrcTask
 rrcTask ──RRC Reconfiguration(DL DCCH)──► rlsTask ──► UE
 ...
 ngapTask ◄──UE Context Release Command── sctpTask
 ngapTask ──NmGnbNgapToRrc(AN_RELEASE)──► rrcTask（对 UE 的 RRCRelease 因非服务小区被 UE 忽略）
 ngapTask ──NmGnbNgapToGtp(UE_CONTEXT_RELEASE)──► gtpTask（释放会话）

[目标 gNB]
 ngapTask ◄──Handover Request── sctpTask
 ngapTask（分配 DL TEID、建 provisional 上下文、记录 pending[sti]）
 ngapTask ──Handover Request Acknowledge──► sctpTask ──► AMF
    ... UE 迁移 ...
 rlsTask ──NmGnbRlsToRrc(UPLINK_RRC, ueId, sti)──► rrcTask
 rrcTask ──NmGnbRrcToNgap(HANDOVER_CONFIRM, ueId, sti)──► ngapTask
 ngapTask（pending[sti] → 真实 ueId 上下文；GTP 建上下文/会话）
 ngapTask ──Handover Notify──► sctpTask ──► AMF
```

## 3. 仿真身份设计

### 3.1 两个问题

1. **目标 gNB 如何知道"马上到达的 UE"就是 Handover Request 所指的 UE？**
   UERANSIM 中 gNB 的 UE ID 是各 gNB 自己的 RLS 在收到该 UE 首个心跳时**本地分配**的（`++m_newIdCounter`），两边并不相同。社区 PR 方案用 `reserveNewUeId()` 返回"最后一个已分配 ID"，在多 UE 或不同发现顺序下会错配。
2. **UE 如何知道切换命令里的目标小区对应本地哪个小区？**
   UE 的 `cellId` 是按发现顺序本地编号的计数器，与 gNB ID 无固定关系。社区 PR 方案直接把目标 gNB ID 当 `cellId`，仅在"gnbId == 该小区被发现的序号"时巧合成立。

### 3.2 本实现

- **跨 gNB UE 身份 = RLS STI**：UE 的 STI 由 UE 节点名派生（`Random::Mixed(nodeName)`），随每次心跳广播，源/目标 gNB 都能观察到同一值。源 gNB 在 Handover Required 的 Source-To-Target 透明容器中携带 `{ueSti}`；目标 gNB 收到后创建 **provisional 上下文**（负数临时 ID）并记录 `pending[sti]`。
- **UE 的出现即确认**：UE 迁移到目标小区后发送 RRC Reconfiguration Complete；目标 gNB 的 RLS→RRC→NGAP 链路携带 `sti`，NGAP 以 `pending[sti]` 将 provisional 上下文**改键**为真实 `ueId`（复用此前 Acknowledge 中已告知 AMF 的 RAN-UE-NGAP-ID），随后建 GTP 会话并发 Handover Notify。
- **目标小区定位 = NCI**：目标 gNB 在自己生成的 Target-To-Source 容器中携带**本小区 NCI**（实际配置值）；UE 用 SIB1 已获知的各小区 NCI 匹配（`ho::FindCellByNci`），找到本地 `cellId` 后切换服务小区。
- **确定性小区选择**：同信号强度按较小 NCI 择先（`ho::IsBetterCell`）。两个 gNB 默认坐标下信号相同，保证 UE 初始驻留到 NCI 较小者（gnb1），演示可复现。

### 3.3 透明容器格式（仿真自定义）

标准 NGAP 信封：`SourceNGRANNode-ToTargetNGRANNode-TransparentContainer.rRCContainer` / `TargetNGRANNode-ToSourceNGRANNode-TransparentContainer.rRCContainer`（OCTET STRING）。其中载荷为仿真格式（UERANSIM 的空口本身即内部模拟，不存在真实 RRC PDU）：

| 载荷 | 字节布局 | 说明 |
|---|---|---|
| `SourceInfo`（源→目标） | `0xA1 + 8 字节大端 ueSti + 8 字节大端 ho_id`（共 17 字节） | 跨 gNB 的 UE 标识 + 切换关联 ID（源侧生成，供两侧事件日志配对） |
| `CommandInfo`（目标→源→UE） | `0xA2 + 5 字节大端 NCI（36bit，高 4 位须为 0）` | 目标小区定位 |

`ho::Decode*` 对标记、长度、NCI 位宽做严格校验，非法输入返回空。

### 3.4 目标小区 NCI 的推导（源侧视图）

真实网络中源 gNB 通过 ANR/OAM 获知邻区 CGI。仿真中约定 **NCI = gNB ID（idLength 位）+ 小区部分（0）**，即 `nci = gnbId << (36 - idLength)`（与 UERANSIM 配置约定、NG Setup 中的 GlobalGNB-ID 编码一致）。`handover` CLI 只给出目标 gNB ID，源侧据此推导 TargetID 与透明容器中的 CGI。**配置模板遵循该约定**（gnb1: `nci=0x000000010` → gNB ID 1；gnb2: `nci=0x000000020` → gNB ID 2）。

> **扩展点（已评估、暂缓）**：当需要"不同配置的邻区"（跨 TAC/PLMN、非约定 NCI）时，可将上述约定替换为 gNB YAML 的 `neighbors:` 邻区表（gNB ID / PLMN / TAC / NCI）。改动集中在源侧触发时的一次目标解析（约 0.5–1 人天、向后兼容、无 UE/目标侧联动）；当前按范围决定维持约定模型，待实验出现该需求时实施。

---

## 4. 目标侧 pending 切换的生命周期

| 阶段 | 动作 |
|---|---|
| 收到 Handover Request | 解析 STI；清理同 STI 的旧 pending（重复切换）；建 provisional 上下文（负 ID、`ranUeNgapId=++counter`、`amfUeNgapId` 来自消息）；逐会话解出 AMBR/类型/UL 隧道/QoS；校验（仅 IPv4、UL 隧道与 QoS 必需）；分配 `downTunnel`（本 gNB GTP IP + `++m_downlinkTeidCounter`）；构造 Admitted/Failed 列表与 Target-To-Source 容器；发 Acknowledge；登记 `pending[sti]` |
| 全部会话被拒 | 发 **Handover Failure**（cause=no radio resources available in target cell），删除 provisional 上下文 |
| 收到切换确认 | 释放同名旧上下文（若存在，通知 GTP 释放）；provisional → 真实 ueId 改键（**复用已通告的 RAN-UE-NGAP-ID**）；GTP 建 UE 上下文与各会话（含 TEID 替换逻辑）；发 Handover Notify |
| 超时（60s） | NGAP 定时器（5s 周期）清理 pending：删除 provisional 上下文与未使用的会话资源并记录告警 |
| AMF 提前释放 | `UE Context Release Command` 按 RAN-ID 命中 provisional 上下文时正常应答；pending 由超时清理兜底 |

## 5. 与 3GPP 步骤的对应

| TS 23.502 §4.9.1.3 步骤 | 实现 |
|---|---|
| 准备 1：Handover Required | ✅ 源 gNB `sendHandoverRequired`（含 TargetID、PDU 会话列表、Source-To-Target 容器、UE 历史；`directForwardingPathAvailability=directPathAvailable`，转发始终启用） |
| 准备 4/7（SMF 交互） | 由 5GC 完成（本项目不实现 5GC） |
| 准备 9：Handover Request | ✅ 目标 gNB `receiveHandoverRequest` |
| 准备 10：Handover Request Acknowledge | ✅ 含 Admitted/Failed 列表、Target-To-Source 容器；失败用 Handover Failure |
| 执行 1：Handover Command | ✅ 源 gNB 收包、解析每会话 DL 转发 TNL（`PDUSessionResourceHandoverList`）并建立重定向 |
| 执行 2：RRC 切换命令 | ✅ RRC Reconfiguration（仿真载荷） |
| 执行 3：数据转发（3a/3b） | ✅ 源侧重定向（按命令给出的 TNL）+ 目标侧接收/缓存/会话寿命别名；封装携带 UL 变体 PDU Session Container（QFI）；End Marker 转发（v2.1） |
| 执行 4：Handover Confirm | ✅ RRC Reconfiguration Complete → `HANDOVER_CONFIRM` |
| 执行 5：Handover Notify | ✅ 自动附加 AMF-UE-NGAP-ID / RAN-UE-NGAP-ID / UserLocationInformation（复用既有 `sendNgapUeAssociated`） |
| 执行 12：移动性注册更新 | ✅ TAI 变化时 UE NAS 触发（`ENTER_UNLISTED_TRACKING_AREA`）；同 TAC 时不触发 |
| 执行 14：UE Context Release | ✅ 复用既有 `receiveContextRelease`（GTP 会话释放、RRC 释放） |
| 失败：Preparation Failure | ✅ 源侧记录 cause（不做自动重试） |

## 6. 简化点与偏差（相对规范）

| # | 简化 | 原因/影响 |
|---|---|---|
| 1 | 透明容器内为仿真载荷，非真实 RRC ASN.1；无 AS 安全（`SecurityContext`/`securityResult` 省略） | UERANSIM 空口为内部模拟，无真实 AS 层 |
| 2 | 触发为 CLI（代替测量报告/无线原因判断） | 仿真触发手段 |
| 3 | 转发为**会话级**（非 QoS 流级）；无 PDCP SN/重排序（FIFO 缓存 + "flush 先于新数据"）；End Marker 转发（源）/记录（目标），无重排序语义（v2.1） | 仿真中 QoS 流级与 PDCP 重排序不可观测；转发与 per-flow `dataForwardingAccepted` 已实现（v2/v2.1，2026-10-01） |
| 4 | 不实现 RAN Status Transfer / PDCP SN 与 HFN 保持 | 无损切换语义不模拟 |
| 5 | 不实现 DAPS、Handover Cancel、Handover Success | 基础场景之外 |
| 6 | TNGRELOCprep/TNGRELOCoverall 已实现（常数 5 s / 10 s） | prep 超时本地中止（不发 Handover Cancel，偏差）；overall 超时停止转发并请求释放（TS 38.413 §8.4.1.2/§9.6） |
| 7 | 目标小区 NCI 由 gNB ID 约定推导（见 §3.4） | 仿真中替代 ANR/OAM |
| 8 | 假定两 gNB 同 PLMN/TAC（TargetID 的 selectedTAI 用源侧配置） | 基础场景；跨 PLMN/TAC 需扩展 |
| 9 | 每次 Handover Required 携带"全部 PDU 会话" | 与规范一致；但 QoS 流级失败处理从简（会话级） |
| 10 | 目标公告的转发 TEID 按**会话寿命别名**保留（不随窗口释放） | Open5GS 实测把该 TNL 用作会话常规 DL 路径（释放即 DL 黑洞）；free5GC 下为空闲条目 |

## 7. 与 ueransim-ims 补丁的共存设计

| 冲突点 | 处理 |
|---|---|
| 根 `CMakeLists.txt` | ims 在 `src/ue` 之后插入 tests 块；本补丁在**文件末尾**追加 `enable_testing()` + `add_subdirectory(tests/handover)` — 两处上下文互不重叠，任意顺序均可应用 |
| `tests/` 目录 | ims 创建 `tests/CMakeLists.txt`；本补丁使用**子目录** `tests/handover/`，不与其产生文件级冲突 |
| `src/lib/app/cli_cmd.*` | ims 改 UE 命令区（`g_ueCmdEntries`/`UeCliParseImpl`）；本补丁改 gNB 命令区（`g_gnbCmdEntries`/`GnbCliParseImpl`），区域分离 |
| `src/ue/nts.hpp` | ims 在文件末追加 IMS 消息；本补丁在既有枚举中间插入两个事件，区域分离 |

验证方式（见 `BUILD.md`）：在干净 v3.3.0 上分别执行 `ims→n2`、`n2→ims` 两种 apply 顺序，编译并运行 `ctest`（两套测试 2/2 通过）。
