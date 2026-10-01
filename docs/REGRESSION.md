# 本地回归测试记录（REGRESSION）

> 日期：2026-09-29
> 环境：Ubuntu 22.04 / 内核 6.8.0-138 / g++ 11.4 / CMake 3.22.1 / libsctp-dev（宿主机原生构建）
> 5GC：free5GC **v4.2.3** 容器（gtp5g v0.10.2 内核模块）+ 两个 UERANSIM gNB（10.100.200.101/.102）+ 多 UE
> 被测：UERANSIM v3.3.0 + `patch/n2handover.patch`（分支 `n2-handover`）
> 方法：包级（离线补丁/构建/单测）+ 功能级（真实 5GC 端到端）+ 基线对照（未打补丁 v3.3.0）

---

## 1. 包级回归（离线）

| # | 场景 | 结果 |
|---|---|---|
| A1 | 干净 v3.3.0 apply `n2handover.patch` → 构建 → `ctest` | ✅ 构建成功；`ho-tests` 1/1（23 项断言，v2 起含转发缓冲 9 项） |
| A2 | `ims.patch` → `n2handover.patch` → 构建 → `ctest` | ✅ 2/2（`ims-tests` + `ho-tests`） |
| A3 | `n2handover.patch` → `ims.patch` → 构建 → `ctest` | ✅ 2/2 |
| A4 | 补丁与已提交代码一致性（`git diff` 对比补丁文件） | ✅ 哈希一致 |

（A1–A3 在宿主机原生与 Docker 容器两种工具链下均执行通过。）

## 2. 功能级回归（在线）

拓扑：gnb1/gnb2 为源/目标；UE 与订阅者：

| UE | 订阅者 | PDU 会话 | 说明 |
|---|---|---|---|
| ue | imsi-…001 | 1（10.60.x） | 基础场景 |
| ue2 | imsi-…002 | 1 | 多 UE 并行 |
| ue3 | imsi-…003 | **2**（10.60.x + 10.61.x） | 多会话切换 |

| # | 测试 | 结果 |
|---|---|---|
| T1 | 基线：3 UE 注册 + 4 条隧道 ping | ✅ 全部 0% 丢包 |
| T2 | 逐 UE 切换（ue1→gnb2、ue2→gnb2），其余 UE 不受影响 | ✅ 源/目标 `ue-list` 正确；ping 全通 |
| T3 | **多会话切换**：ue3（2 会话）→ gnb2，目标日志 `2 session(s) admitted, 0 rejected` | ✅ 两条隧道 ping 全通 |
| T4 | 反向切换（ue3 → gnb1；ue1/ue2 回切） | ✅ 全通（验证反复切换与上下文/TEID 替换） |
| T5 | `ue-release`（NG-RAN 主动释放）：源侧 ctx 释放、UE 转 CM-IDLE | ✅ 释放路径正常（见观察 1：原地数据恢复为上游限制） |
| T5b | UE 重启后恢复：重新注册 + 重建会话 + ping + 切换 | ✅ 全通 |
| T6 | `ps-release-all` + `ps-establish`（CLI 重建会话） | ✅ 释放正常；首次重建被 SMF 瞬时拒绝、重试成功（观察 2） |
| T7 | **失败路径**：无任何 PDU 会话的 UE 触发切换 | ✅ 源侧记录 `handover preparation failure`；UE 保持驻留源 gNB；无崩溃 |
| T8 | 三 UE 全部切换 + 回切，最终 4 隧道 ping | ✅ 全部 0% 丢包 |
| T9 | 日志卫生：扫描 gnb1/gnb2/ue* 的 `[error]` 并分类 | ✅ 无未解释错误（见观察 1–3） |
| C1 | **对照实验**：未打补丁 v3.3.0 执行 T5 的"释放 + 数据恢复" | ✅ 与打补丁版本**行为完全一致**（证明非本补丁回归） |

## 3. 关键观察（均为上游或 5GC 侧行为，非本补丁回归）

1. **Service Request 原地恢复受限于上游 `selectAmf`**：UE 被 `ue-release` 释放后，上行数据触发的 Service Request 无 Requested NSSAI，gNB 的 `selectAmf` 需要 slice 精确匹配（`-1` 必然失败），日志为
   `AMF selection for UE[x] failed. Could not find a suitable AMF.` + `AMF context not found with id: 0`，数据面不恢复。
   **基线对照（C1）在未打补丁的 v3.3.0 上复现完全相同的日志与 100% 丢包**；本补丁未改动 `nnsf.cpp`（`selectAmf`）与 `extractSliceInfoAndPdu`。
   *规避*：重启 UE（重新注册，走带 NSSAI 的 Registration Request）即可恢复。
2. **free5GC 侧释放/重建竞态**：`ps-release-all` 后立即 `ps-establish`，首次可能收到 `DNN_NOT_SUPPORTED_OR_NOT_SUBSCRIBED`（SMF 日志见 `Cause_REL_DUE_TO_DUPLICATE_SESSION_ID`），重传（T3580）后成功。属 5GC 内部状态处理，与本补丁无关。
3. **GTP-U End Marker（类型 254）**：路径切换后 UPF 在旧路径发送 End Marker，UERANSIM 上游 GTP 任务未实现该消息，记录 `Unhandled GTP-U message type: 254`。这是"不实现 gNB 间转发"简化的直接结果（End Marker 无需转发时可直接忽略），不影响数据面。
4. **孤立 NGAP 上下文**：AMF 选择失败/释放等场景会在 `ue-list` 留下 `amf-ngap-id: -1` 的孤儿上下文（上游无清理路径）。RLS UE ID 单调递增、永不复用，且本补丁的 UE 匹配以 STI 为准，因此孤儿上下文**无害**（重启 gNB 即消失）。
5. **STI 会在重连后变化**：UE 重新建立 RRC 时更新 STI（`RESET_STI`）。本实现每次切换触发时从 RLS 实时读取当前 STI 并以透明容器传递，因此天然兼容。

## 4. 复现要点（关键命令）

```bash
# 包级
git clone https://github.com/aligungr/UERANSIM && cd UERANSIM && git checkout v3.3.0
git apply <deliver>/patch/n2handover.patch
cmake -S . -B build && cmake --build build -j$(nproc) && ctest --test-dir build --output-on-failure

# 功能级（见 docs/RUN.md）：核心网 → provision-subscriber.sh → gnb1/gnb2/ue
./run-handover.sh <ue-id> <target-gnb-id>        # 交付脚本触发切换
docker exec ue ping -I uesimtun0 -c 5 10.100.200.1   # 切换前后数据面

# 多 UE/多会话：为额外订阅者（唯一 GPSI）开通后，以同一模式启动额外 nr-ue
# 失败路径：启动一个不含 sessions 的 UE 配置，注册后直接触发 handover
```

## 5. Open5GS VoNR 验收（含 IMS 通话中切换）

除 free5GC 外，另在 **docker_open5gs（`sa-vonr-deploy.yaml`）** 上完成两项目标验收：
① **Open5GS 兼容性**；② **IMS 通话中 N2 切换的连续性**（下游任务的验收场景，非补丁功能本身）。

环境：docker_open5gs（Open5GS + Kamailio 6.2.0-dev1 + pyHSS，PLMN 001/01，TAC 1，SST 1）、
UERANSIM 为 **n2handover + ims 补丁合并构建**；测试床资产、步骤与排错见 `deploy/open5gs/README.md`。

| # | 测试 | 结果 |
|---|---|---|
| O1 | 两 UE 接入 + 双 PDU 会话（internet + ims）+ IMS 注册 | ✅ 均成功 |
| O2 | VoNR 通话建立（UE1→UE2 自动应答，rtpengine 双向 RTP） | ✅ 双方 CONFIRMED |
| O3 | 通话中切换 UE1（gNB1→gNB2）与回切（gNB2→gNB1） | ✅ 两次均保持 CONFIRMED |
| O4 | RTP 缺口（75 s 抓包，含两次切换窗口） | ✅ 双向最大 **39.8–40.9 ms**，>60 ms 间隔 **0** |
| O5 | 事件日志相关性（源/目标同一 `ho_id`，阶段序列完整） | ✅ |

证据摘要：`deploy/open5gs/evidence/ims-handover-summary.txt`；一键脚本：`deploy/open5gs/run-ims-test.sh`。

为在 Open5GS 上跑通 IMS 测试，对 docker_open5gs 应用了 3 处**测试床适配**（I-CSCF 单 S-CSCF 直连、
P-CSCF 关闭 IPSec/TCP 监听、PCF `qos_profiles` + IMS PCC 规则；脚本
`deploy/open5gs/tweaks/apply-open5gs-tweaks.sh` 幂等应用）。这些适配仅涉及 5GC/IMS 配置，
**不涉及本补丁代码**；N2 切换在 Open5GS 上的行为与 free5GC 一致（含路径切换后源侧释放、
目标侧 AMF-UE-NGAP-ID 重新分配的处理）。

## 6. free5GC + IMS 验收（与 Open5GS 对比）

在同一 IMS 栈、同一 UE 客户端与同一测量口径下，另在 **free5GC v4.2.3** 上完成"IMS 通话中 N2 切换"
验收（方案 L：free5GC 仅加 `ims` DNN 与开户；IMS 侧复用 docker_open5gs 组件；N5/RX 关闭）：

| # | 测试 | 结果 |
|---|---|---|
| F1 | 两 UE 接入 + 双会话（internet+ims）+ IMS 注册 | ✅（P-CSCF 经 ePCO 下发：`pcscf=10.100.200.47 (EPCO)`） |
| F2 | 通话 + **10 次往返切换（20 次）** | ✅ 20/20 保持 `CONFIRMED` |
| F3 | RTP 缺口（阈值 60 ms） | ✅ 最大 ~41 ms，**>60 ms 中断 0** |
| F4 | 与 Open5GS 基线对比（同协议） | ✅ RTP 连续性等价；控制面差异：prep 21–27 vs 11–13 ms、源侧释放 207–219 vs 501–508 ms |

证据：`deploy/free5gc-ims/evidence/`；步骤、坑与排错：`deploy/free5gc-ims/README.md`。
说明：本补丁（N2 切换）在 free5GC 与 Open5GS 上**行为一致**（控制面流程、`ho_id` 事件序列、切换后
数据面路径切换均正常）；差异项均在 5GC 实现侧。free5GC/IMS 侧全部为环境配置改动（幂等脚本），补丁代码未变。

## 7. 结论

- 补丁**未引入对既有功能的回归**（含基线对照验证）；
- N2 切换的正常路径（单 UE / 多 UE / 多 PDU 会话 / 反复切换）与失败路径（Preparation Failure）均按规范行为工作；
- 观察 1–5 已记录，其中 1 为上游限制（有基线证据）、2 为 5GC 侧竞态、3–5 为已知简化的自然表现。

## 8. v2 数据转发回归（2026-10-01）

**包级（干净 v3.3.0，三个场景重跑）**：仅 n2 / ims→n2 / n2→ims 均 apply + 构建通过；ctest 1/1、2/2、2/2；补丁 3334 行（v1 2573）。

**功能级（两核 IMS 通话中切换，各 10 次往返 / 20 次切换）**：

| 指标 | free5GC | Open5GS |
|---|---|---|
| 通话保持 | 20/20 CONFIRMED | 20/20 CONFIRMED |
| RTP 缺口 max（ue1 DL / UL） | 40.8 / 41.2 ms | 40.3 / 40.9 ms |
| >60 ms 中断 | 0 | 0 |
| UE 侧 mediaTx/mediaRx 差（ue1） | 3 包 | 0 包 |
| 源侧转发计数（每次切换，IMS 会话） | 10–11 包 | 9–10 包 |
| 未知 TEID / 定时器噪声 | 0 | 0 |
| 控制面（prep / release） | 22–30 / 210–222 ms | 11–13 / 500–508 ms |

- v1 归档对照（同口径）：RTP max 40.9/41.2（Open5GS）、41.0/40.6（free5GC），>60 ms 中断 0 —— v2 无回归；
- 转发功能证据：源 `data forwarding started/active(QFI)/stopped(N packets)`、目标 `endpoint registered/flushed/alias`、两核均无 `TEID not found`；
- 证据：`deploy/open5gs/evidence/ims-handover-summary-v2-forwarding.txt`、`deploy/free5gc-ims/evidence/free5gc-ims-handover-summary-v2-forwarding.txt`。

**新增观察（free5GC 运维）**：中断的切换流程（例如对错误 ue-id 触发）会令 AMF 残留 `N2 handover is ongoing`，随后该 UE 的注册被拒（`Registration Reject [CONGESTION]`）；重启 `amf/smf/upf` 并重连 gNB/UE 恢复。另：验收脚本的 ue-id 跟踪已从"目标列表差分"改为**目标 gNB 日志权威 id**（free5GC 下 id 会复用，差分失效）。

### 8.1 v2.1 标准对齐（2026-10-01）

- 变更（commit `352983b`，补丁 3452 行）：C1 per-flow `dataForwardingAccepted`；C2 尊重 `DataForwardingNotPossible`（不公告转发端点）；C3 End Marker 转发（源）/记录（目标）；C4 失败会话列表解析与本地释放；
- free5GC 复验（10 次往返/20 次切换）：通话 20/20 CONFIRMED；RTP max ue1 DL 38.1 / UL 41.1 ms、>60 ms 中断 0；ue1 计数差 1 包；**end marker 20/20 转发并接收、`Unhandled GTP-U` 归零**；
- 多 UE 并发切换（ue1+ue2 先后切出再切回）：双向 ping 0% 丢包、每 UE 独立 STI/TEID、无交叉；无 `TEID not found`；
- 失败路径（确定性）：切换到不存在的目标 gNB[9] → 源侧 `Handover Required sent` 后 5 s **TNGRELOCprep 超时本地中止**（不发 Cancel，文档化偏差）、**未建立转发**、UE 驻留源侧；free5GC AMF 对无效 TargetID 未回 PreparationFailure（核心网行为）；
- 未在实测中触发（代码路径就位）：C2（核心网未置 `DataForwardingNotPossible`）、C4（无失败会话）；
- 运维注记：验收脚本假定 ue1 起始在 GNB1；否则 `handover` 命令空跑（事件日志无新增、RTP 窗口 n/a）。
- 证据：`deploy/free5gc-ims/evidence/free5gc-ims-handover-summary-v21-standard-alignment.txt`。
