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
| A1 | 干净 v3.3.0 apply `n2handover.patch` → 构建 → `ctest` | ✅ 构建成功；`ho-tests` 1/1（14 项断言） |
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

## 5. 结论

- 补丁**未引入对既有功能的回归**（含基线对照验证）；
- N2 切换的正常路径（单 UE / 多 UE / 多 PDU 会话 / 反复切换）与失败路径（Preparation Failure）均按规范行为工作；
- 观察 1–5 已记录，其中 1 为上游限制（有基线证据）、2 为 5GC 侧竞态、3–5 为已知简化的自然表现。
