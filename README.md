# UERANSIM-N2handover

在 [UERANSIM](https://github.com/aligungr/UERANSIM) **v3.3.0** 上以补丁形式实现的 **N2 切换（NG-RAN 间 N2-based Handover）仿真**：`nr-cli` 触发，源 gNB 经 N2（NGAP）向 5GC 发起切换，目标 gNB 分配资源并公告数据转发端点，UE 完成"空口"重配并迁移，5GC 完成下行路径切换与源侧释放。补丁主体为 `patch/n2handover.patch`（v1→v2.2 全部功能），另含部署资产、双核（free5GC / Open5GS）验收证据与文档。

仿真"空口"以 RLS **STI** 跨 gNB 标识 UE、以 **NCI** 让 UE 定位目标小区；透明容器为仿真自定义载荷（标准 NGAP 信封不变）。v2 起实现 gNB 间**数据转发**（直连/间接两种核心网口味统一处理），v2.2 起实现 **Handover Cancel**。

## 特性

- **CLI 触发**：源 gNB 执行 `handover <ue-id> <target-gnb-id>`；发送 **Handover Required**（HandoverType=intra5gs、TargetID、PDU 会话列表、源→目标透明容器、UE 历史、`directForwardingPathAvailability`）
- **准备阶段**：目标 gNB 逐会话分配下行 N3 端点与**转发专用 TEID**，返回 **Handover Request Acknowledge**（Admitted/Failed 列表、`dLForwardingUP_TNLInformation`、per-flow `dataForwardingAccepted`）；尊重 `DataForwardingNotPossible`；全部被拒返回 **Handover Failure**
- **执行阶段**：源 gNB 解析 Handover Command（每会话转发 TNL + 失败会话列表）→ RRC Reconfiguration → UE 迁移 → 目标发 **Handover Notify** → 5GC 路径切换 → 源侧 **UE Context Release**
- **数据转发（v2/v2.1）**：源侧把切换窗口内 DL 重定向到命令给出的转发 TNL（封装携带 UL 变体 PDU Session Container/QFI）；目标侧接收/缓存（256 包 / 1 MB，丢最旧）并在 UE 到达后按序交付；目标公告的转发 TEID 保留为**会话寿命别名**（部分核心网持续用它下发 DL）；**End Marker** 源侧转发、目标侧记录
- **定时器与取消（v2.2）**：`TNGRELOCprep`（5 s）/`TNGRELOCoverall`（10 s）按规范起止；prep 超时发起 **Handover Cancel**（cause=tngrelocprep expiry；Ack 处理，缺失按 TS 38.413 §8.4.5.4 视为成功）；overall 超时按规范 cause 请求释放
- **失败与异常**：Preparation Failure 记录原因（迟到消息在无 pending 准备时忽略）；目标侧 pending 超时清理；部分会话失败由源侧解析并本地释放
- **可重复切换**：gNB1 ⇄ gNB2 反复切换（陈旧 UE 上下文、DL TEID 替换、转发 TEID 别名均处理）
- **结构化事件日志**：每 gNB 写 `logs/<gnb-name>.ho-events.jsonl`（`ho_id` 贯通源/目标、阶段枚举、单调/挂钟时间戳），零新增配置项；配套 `deploy/ho-batch.sh` 批量往返驱动
- **单元测试**：`ctest`（23 项）覆盖透明容器编解码、确定性小区排序、目标小区解析、事件序列化、转发缓冲（FIFO/上限/丢最旧）
- **与 ueransim-ims 补丁共存**：两种 apply 顺序均可干净应用，双测试套件（`ims-tests` + `ho-tests`）全绿

## 架构

```
src/gnb/ngap/handover.cpp     切换流程：Required / Request / Ack / Command / Notify / Cancel、TNGRELOC 定时器
src/gnb/gtp/task.cpp          用户面：源侧重定向、目标侧接收/缓存/会话寿命别名、End Marker
src/gnb/gtp/forwarding.cpp    有界转发缓冲（纯逻辑，可单测）
src/gnb/nts.hpp               NGAP↔GTP 转发消息（SETUP / START / FLUSH / STOP / TEARDOWN）
tests/handover/               ho-tests：纯函数单元测试
```

控制面与用户面：

```
准备： 源 gNB ──Handover Required──► AMF ──► SMF ──► 目标 gNB（分配 N3 + 转发端点）──Ack──► 源 gNB
执行： 源 gNB ──Handover Command──► UE（RRC 重配）──► 目标 gNB ──Handover Notify──► 5GC ──路径切换──► 源侧释放
转发： 源 gNB ──(窗口内 DL 重定向)──► 转发 TNL（直连=目标 gNB / 间接=UPF）──► 目标 gNB 缓存 ──UE 到达后──► UE
```

简化点（相对规范，详见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §6）：透明容器为仿真载荷（无真实 RRC ASN.1 / 无 AS 安全）；转发为会话级（非 QoS 流级）；无 PDCP SN/重排序（FIFO + flush 先于新数据）；不做 RAN Status Transfer / DAPS / AMF 重定位 / UL 转发 / CHO。

## 快速开始

依赖：Ubuntu 22.04、cmake ≥ 3.17、g++ ≥ 11、libsctp-dev。

```bash
# 1. 拉取 UERANSIM v3.3.0 并应用补丁
git clone https://github.com/aligungr/UERANSIM
cd UERANSIM && git checkout v3.3.0
git apply <path-to>/ueransim-N2handover/patch/n2handover.patch

# 2. 构建与单测
cmake -S . -B build && cmake --build build -j$(nproc)
ctest --test-dir build --output-on-failure

# 3. 端到端（free5GC / Open5GS 测试床 + 一键验收脚本）
#    见 deploy/open5gs/README.md 与 deploy/free5gc-ims/README.md
```

详见 [docs/BUILD.md](docs/BUILD.md) 与 [docs/RUN.md](docs/RUN.md)。

## 文档

| 文档 | 内容 |
|------|------|
| [docs/BUILD.md](docs/BUILD.md) | 依赖、从零编译、补丁应用与共存矩阵、单元测试 |
| [docs/RUN.md](docs/RUN.md) | 端到端运行（free5GC/Open5GS）、触发切换、转发/取消日志、排错 |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 模块设计、与 3GPP 步骤对应、简化点与偏差 |
| [docs/MEASUREMENT.md](docs/MEASUREMENT.md) | 事件日志 schema、批量驱动、IMS 连续性取证方法 |
| [docs/REGRESSION.md](docs/REGRESSION.md) | 回归记录：包级矩阵、功能级、v1→v2.2 验收与基线对照 |
| [docs/STANDARDS-AUDIT.md](docs/STANDARDS-AUDIT.md) | 规范原文审计（TS 38.413 / 23.502 / 38.300 逐条核对） |

## 验证状态

- ✅ **包级**：干净 v3.3.0 apply 构建；与 `ueransim-ims` 共存（两种顺序）双测试套件全绿；`ho-tests` 23 项
- ✅ **free5GC 端到端**：多次切换（含反向、多会话、多 UE）、ping 0% 丢包、事件日志 `ho_id` 贯通、失败路径（Preparation Failure）
- ✅ **数据转发（v2/v2.1）**：free5GC/Open5GS 各 10 次往返（20 次切换）通话保持 CONFIRMED；RTP 最大间隔 ~41 ms、>60 ms 中断 0；UE 侧 `mediaTx/mediaRx` 差 0–3 包；每切换源侧转发 9–11 个 IMS 媒体包；End Marker 20/20 转发并接收；多 UE 并发切换隔离（双向 0% 丢包）
- ✅ **标准对齐（v2.1）**：`dataForwardingAccepted`、`DataForwardingNotPossible`、失败会话列表、TNGRELOCoverall cause；规范原文逐字核对通过
- ✅ **Handover Cancel（v2.2）**：prep 超时发起 Cancel + Ack 处理 + 目标侧容忍释放；free5GC 实测 AMF 处理并清除陈旧 "N2 handover is ongoing" 状态
- ✅ **结构化事件日志 + 批量驱动**：JSONL schema 稳定，`deploy/ho-batch.sh` 批量往返

## 版本

- **v1**：控制面 + 基础用户面、结构化事件日志（UERANSIM `e0112ad`/`ab6b021`）
- **v2**：数据转发（源侧重定向 + 目标侧缓存/会话寿命别名）、TNGRELOC 定时器（`a41aca0`…`d0a2940`）
- **v2.1**：标准对齐 + overall 超时 cause（`352983b`/`4e29d0e`）
- **v2.2**：Handover Cancel（`5aacad9`）

## 许可

本项目是 [UERANSIM](https://github.com/aligungr/UERANSIM)（GPL-3.0）的衍生修改，随附 [LICENSE](LICENSE)。
