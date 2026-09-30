# 测量与事件日志（MEASUREMENT）

本文说明本交付用于**切换时序测量**与**业务连续性取证**的三件套：结构化事件日志、批量切换驱动、RTP/IMS 取证方法。三者均为**服务无关**的通用能力（不感知 IMS/SIP/RTP 等上层业务）。

---

## 1. 切换事件日志（JSONL）

### 1.1 位置与开关

- 每个 gNB 进程写自己的文件：**工作目录**下 `logs/<gnb-name>.ho-events.jsonl`
  - 例：`logs/UERANSIM-gnb-208-93-1.ho-events.jsonl`（= `/ueransim/logs/...` 于容器部署）
- **始终开启，零新增配置项**；目录自动创建，创建/写入失败只告警、不影响切换流程
- **追加写**（多次实验累积），以 `ho_id` 区分每次切换
- 人类可读日志不受影响（仍走 stdout，`docker logs` / 终端可见）

### 1.2 查看方式

```bash
# 原生运行（在 nr-gnb 的工作目录）
tail -f logs/UERANSIM-gnb-208-93-1.ho-events.jsonl

# 容器运行（deploy/docker-compose.n2handover.yaml 已挂载 ./ho-events/<gnb>）
tail -f ho-events/gnb1/UERANSIM-gnb-208-93-1.ho-events.jsonl
# 或
docker exec gnb1 tail -n 20 /ueransim/logs/UERANSIM-gnb-208-93-1.ho-events.jsonl
```

> 容器写入的文件属主为 root（容器内以 root 运行）；如需改为当前用户属主，可在容器启动前预创建 `ho-events/` 目录或在实验后 `sudo chown`。

### 1.3 Schema

```json
{"schema":"ueransim-ho-event/1",
 "ho_id":1877673865716432897,
 "wall_ms":1790689340321,
 "mono_ms":21990324,
 "node":"UERANSIM-gnb-208-93-1",
 "role":"source",
 "phase":"HO_REQUIRED_SENT",
 "ue":{"id":4,"sti":7922447756896870551,"ran_ngap_id":3,"amf_ue_ngap_id":24,"nci":16},
 "sessions":[1,2]}
```

| 字段 | 说明 |
|---|---|
| `ho_id` | 一次切换的关联 ID：**源侧生成**、经 Source→Target 透明容器携带到目标，两侧事件据此精确配对（不依赖时间戳猜测） |
| `wall_ms` / `mono_ms` | 挂钟（ms）与宿主单调时钟（ms）；同一宿主上跨容器可比（`mono_ms` 推荐用于计算时长） |
| `role` | `source` / `target` —— 是"本次切换中的角色"，同一进程在不同切换中可不同 |
| `ue.id` | 目标侧在 UE 到达前的 provisional 上下文为负数，到达后改用真实 ue-id（见 `ARCHITECTURE.md` §4） |
| `ue.nci` | 事件产生方的 NCI |
| `sessions` | 该事件关联的 PDU 会话（PSI 列表） |

`phase` 枚举与产生侧：

| phase | 侧 | 产生点 |
|---|---|---|
| `HO_REQUIRED_SENT` | 源 | Handover Required 发出 |
| `HO_COMMAND_RECEIVED` | 源 | Handover Command 收到 |
| `RRC_RECFG_SENT` | 源 | RRC Reconfiguration（切换命令）发出 |
| `UE_CTX_RELEASE_RECEIVED` | 源/目标 | UE Context Release Command 收到（`role` 为该上下文在最近一次切换中的角色） |
| `HO_PREP_FAILURE` | 源 | Handover Preparation Failure 收到（失败路径） |
| `HO_REQUEST_RECEIVED` | 目标 | Handover Request 收到 |
| `HO_ACK_SENT` | 目标 | Handover Request Acknowledge 发出 |
| `HO_FAILURE_SENT` | 目标 | Handover Failure 发出（全拒路径） |
| `RRC_RECFG_COMPLETE_RECEIVED` | 目标 | RRC Reconfiguration Complete 收到（UE 到达） |
| `HO_NOTIFY_SENT` | 目标 | Handover Notify 发出 |

### 1.4 时长口径示例

- 准备阶段（AMF 往返）：`target.HO_REQUEST_RECEIVED.mono_ms − source.HO_REQUIRED_SENT.mono_ms`
- 空口重配（T_ran）：`target.RRC_RECFG_COMPLETE_RECEIVED.mono_ms − source.RRC_RECFG_SENT.mono_ms`
- 完整执行：`target.HO_NOTIFY_SENT.mono_ms − source.HO_COMMAND_RECEIVED.mono_ms`
- 源侧释放：`source.UE_CTX_RELEASE_RECEIVED.mono_ms − target.HO_NOTIFY_SENT.mono_ms`

### 1.5 单测

`tests/handover/ho_tests.cpp` 覆盖：容器编解码（含 `ho_id`）、NCI 解析、小区排序、事件 JSON 序列化与转义。

---

## 2. 批量切换驱动（deploy/ho-batch.sh）

```bash
./ho-batch.sh -n 5 -p -i 3          # 5 次切换，往返模式，间隔 3s
./ho-batch.sh -n 3 -u 1             # 3 次单向切换（显式 ue-id）
```

| 参数 | 说明 |
|---|---|
| `-n` | 切换次数（默认 5） |
| `-i` | 每次切换后的等待秒数（默认 3） |
| `-u` | 显式 ue-id；缺省时每次在**当前源 gNB** 上自动取第一个 UE（注意 ue-id 是各 gNB 本地的，往返模式建议缺省自动） |
| `-p` | 往返模式：每次交替源/目标 gNB |

脚本每次打印源侧最后一条事件（JSON 行）作为过程记录；完整统计请聚合两份 JSONL（见 §1.4）。

---

## 3. IMS 通话连续性取证（Open5GS VoNR）

### 3.1 环境

- `docker_open5gs` 的 `sa-vonr-deploy.yaml`（Open5GS + Kamailio IMS + rtpengine）
- 两个 gNB + 两个 UE（本补丁的 `nr-gnb`/`nr-ue`，UE 使用 `ims.patch` 的内嵌 IMS 客户端，每 UE 两条 PDU 会话：`internet` + `ims`）

### 3.2 步骤（与 `deploy/` 脚本对应）

1. 启动 5GC/IMS 与两个 gNB、两个 UE；两个 UE 完成 `internet`+`ims` 会话与 SIP REGISTER；
2. `ims-call` 由 ue1 呼叫 ue2（ue2 `autoAnswer` 自动应答）；
3. 在 **rtpengine 容器的网络命名空间**内抓包（旁路容器：`docker run --rm --net=container:rtpengine … tcpdump -n -tt -l -i any 'udp and (host <ue1_ims_ip> or host <ue2_ims_ip>)'`）；
   注意：在 UE 容器内对 `uesimtunN`/`any` 抓包看不到本机媒体流（该路径不经 AF_PACKET），因此统一在 rtpengine 侧测量；
4. 触发 ue1 的 N2 切换（`nr-cli handover`），等待流程完成；
5. 复核两侧 `ims-status`（呼叫是否保持）并分析抓包。

> 交付脚本 `deploy/open5gs/run-ims-test.sh` 已把上述流程（含 ue-id 自动识别、双向切换、缺口分析与
> ho-events 相关性）自动化，可直接作为验收入口。

### 3.3 分析口径（可自行调整阈值）

- **中断（gap）**：相邻 RTP 包到达间隔超过阈值（默认 60 ms，即 3×20 ms 包间隔）记为一次中断，跨度 = 间隔 − 20 ms；
- **丢包率**：按序列号（需要 RTP 级别的 seq 解析；本交付给到的是包到达时间线，seq 级分析可结合抓包工具的 RTP 解析）；
- **方向**：按源/目的地址区分 UL/DL，分别统计（DL 中断窗口在切换前后由 5GC 路径切换决定）。

> v2（2026-10-01）起切换**包含 gNB 间数据转发**：DL 在"UE 迁移 → 5GC 路径切换"窗口内由源侧重定向、目标侧缓存/交付，
> 因此 **UE 侧媒体计数（`mediaTx`/`mediaRx` 差分）应接近零差**；rtpengine 侧缺口仍以 UL 方向（UE 切换窗口）为主。
> **实测（2026-10-01，free5GC/Open5GS 各 20 次切换）**：ue1 计数差 0–3 包、RTP >60 ms 中断 0（max ~41 ms，与 v1 归档一致）；
> v1 归档（2026-09-29）：两次切换 RTP 双向最大包间隔 39.8–40.9 ms、无 >60 ms 中断；
> 证据见 `deploy/*/evidence/*v2-forwarding*` 与 `ims-handover-summary.txt`。
