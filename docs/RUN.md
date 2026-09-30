# 端到端运行（RUN）

本文以 **free5GC v4.2.3 docker compose + 两个 UERANSIM gNB + 一个 UE** 为例，完整演示 N2 切换。Open5GS 的差异点见 §7。

> 已验证环境：Ubuntu 22.04 内核 6.8 + Docker Compose v2 + free5GC v4.2.3 容器 + 本补丁构建的 UERANSIM（构建方式见 `BUILD.md` §4 的 Docker 构建）。

---

## 1. 环境与前置条件

| 组件 | 要求 |
|---|---|
| free5GC | `free5gc/free5gc-compose`（默认 v4.2.3 镜像） |
| gtp5g 内核模块 | free5GC 的 UPF 必需（`gtp5g` + 依赖 `udp_tunnel`）。见 §6.1 |
| UERANSIM 镜像 | 构建产物镜像（`ueransim-build:22.04` 或自建运行镜像），含 `nr-gnb`/`nr-ue`/`nr-cli` |
| 资源 | 两个 gNB + UE 容器需要 `NET_ADMIN`；UE 额外需要 `/dev/net/tun` |

## 2. 拓扑与地址规划

```
                    free5GC compose 网络 privnet 10.100.200.0/24
   gnb1 .11 ──N2(SCTP)/N3(GTP)──► AMF .16 / UPF            ◄── N3/GTP ── gnb2 .12
     ▲  RLS(UDP 4997)                                             ▲
     └────────────── UE .21（TUN：5GC 分配 10.60.x.x）────────────┘
```

| 节点 | 地址 | 说明 |
|---|---|---|
| gnb1 | 10.100.200.101 | nci `0x000000010`（gNB ID 1），TAC 1 |
| gnb2 | 10.100.200.102 | nci `0x000000020`（gNB ID 2），TAC 1 |
| ue | 10.100.200.121 | `gnbSearchList: [10.100.200.101, 10.100.200.102]` |
| AMF | 10.100.200.16（别名 `amf.free5gc.org`） | NGAP 38412 |
| UPF | 动态（别名 `upf.free5gc.org`） | N3 GTP-U 2152 |

> 配置文件即 `config/gnb1.yaml`、`config/gnb2.yaml`、`config/ue.yaml`。若两 gNB 部署在不同主机，把 `linkIp/ngapIp/gtpIp` 改为各自可达地址并相应调整 UE 的 `gnbSearchList`。

## 3. 部署 5GC（free5GC compose）

```bash
git clone https://github.com/free5gc/free5gc-compose && cd free5gc-compose
# 将本交付包的 deploy/ 与 config/ 复制到 compose 目录
cp <deliver>/deploy/docker-compose.n2handover.yaml .
cp <deliver>/deploy/provision-subscriber.sh .
cp <deliver>/config/gnb1.yaml config/
cp <deliver>/config/gnb2.yaml config/
cp <deliver>/config/ue.yaml config/

# 指向 UERANSIM 构建目录（含 nr-gnb / nr-ue / nr-cli）
export UERANSIM_BUILD_DIR=/path/to/UERANSIM/build

# 先启动 5GC 核心网（gNB/UE 稍后启动，确保订阅者已开通）
docker compose -f docker-compose.yaml -f docker-compose.n2handover.yaml up -d \
    db free5gc-nrf free5gc-amf free5gc-ausf free5gc-udm free5gc-udr free5gc-pcf free5gc-nssf \
    free5gc-smf free5gc-chf free5gc-upf free5gc-webui
```

## 4. 开通订阅者

WebUI 暴露在宿主机 `http://127.0.0.1:5000`（用户名 `admin` / 密码 `free5gc`）。

```bash
# 等待 WebUI 就绪（通常数秒）
until curl -s -o /dev/null http://127.0.0.1:5000; do sleep 2; done

./provision-subscriber.sh          # 使用与 config/ue.yaml 相同的 K/OPc 开通 imsi-208930000000001
# 也可通过 WebUI 页面手动创建（Profile + Subscriber），SUPI 与密钥须与 ue.yaml 一致
```

## 5. 启动 gNB/UE 并触发切换

```bash
# 5.0 启动两个 gNB 与 UE
docker compose -f docker-compose.yaml -f docker-compose.n2handover.yaml up -d gnb1 gnb2 ue

# 5.1 观察 UE 注册与 PDU 会话（UE 日志）
docker logs -f ue
#     期望出现：RRC connection established / PDU session establishment accept（10.60.x.x）

# 5.2 两 gNB 的 UE 列表（源 gNB 有 UE；目标 gNB 也因心跳发现 UE，但无 NGAP 上下文）
docker exec gnb1 /ueransim/bin/nr-cli --dump
docker exec gnb1 /ueransim/bin/nr-cli UERANSIM-gnb-208-93-1 -e "ue-list"
docker exec gnb2 /ueransim/bin/nr-cli UERANSIM-gnb-208-93-2 -e "ue-list"

# 5.3 触发 N2 切换（UE ID 取源 gNB ue-list 中的 ue-id，通常为 1；目标 gNB 为 2）
docker exec gnb1 /ueransim/bin/nr-cli UERANSIM-gnb-208-93-1 -e "handover 1 2"
#     或使用交付包脚本：deploy/run-handover.sh 1 2
```

### 预期事件序列（日志关键字）

| 侧 | 日志（INFO） |
|---|---|
| gnb1 | `N2 handover: Handover Required sent for UE[1] towards gNB[id 2]` |
| gnb2 | `N2 handover: Handover Request received ...` / `Handover Request accepted ...` |
| gnb1 | `N2 handover: Handover Command received, forwarding the handover command to UE[1]` |
| gnb2 | `N2 handover: handover confirm (RRC Reconfiguration Complete) received from UE[1]` |
| gnb2 | `N2 handover: UE[1] appeared on the target cell` / `Handover Notify sent for UE[1]` |
| gnb1 | `UE Context Release Command received`（5GC 在路径切换后释放源侧） |
| ue | `N2 handover: serving cell changed from cell[x] to cell[y]` / `sending RRC Reconfiguration Complete` |

### 结果确认

```bash
# 目标 gNB 上出现 UE 的 NGAP 上下文（AMF-UE-NGAP-ID 与源侧一致）
docker exec gnb2 /ueransim/bin/nr-cli UERANSIM-gnb-208-93-2 -e "ue-list"

# 源 gNB 侧上下文被释放
docker exec gnb1 /ueransim/bin/nr-cli UERANSIM-gnb-208-93-1 -e "ue-list"

# 数据面：UE 迁移后仍可收发（以下以 ping 宿主机网桥网关为例，视 5GC 路由/NAT 而定）
docker exec ue ping -I uesimtun0 -c 3 10.100.200.1
```

## 6. 排错

### 6.1 gtp5g 内核模块（free5GC UPF 必需）

```bash
# 1) 编译（需内核头文件；Ubuntu 内核对 gcc 版本有要求，6.8 内核用 gcc-12）
sudo apt install -y build-essential gcc-12 linux-headers-$(uname -r) kmod
git clone -b v0.10.2 https://github.com/free5gc/gtp5g.git && cd gtp5g
make CC=gcc-12 -j$(nproc)

# 2) 正式安装（安装后可直接 modprobe；依赖 udp_tunnel 会自动加载）
sudo mkdir -p /lib/modules/$(uname -r)/extra
sudo cp gtp5g.ko /lib/modules/$(uname -r)/extra/
sudo depmod -a
sudo modprobe gtp5g
lsmod | grep gtp5g

# 可选：开机自动加载
echo gtp5g | sudo tee /etc/modules-load.d/gtp5g.conf
```

> 若仅用特权容器临时加载（无本地 root 时）：容器内 `insmod` 后宿主内核同样生效，但**重启后失效**。

容器内构建（无本地编译环境、宿主 docker 可用时）：

```bash
docker run --rm --privileged -v $PWD:/work ubuntu:22.04 bash -lc '
  apt-get update && apt-get install -y build-essential gcc-12 kmod linux-headers-$(uname -r) &&
  cd /work/gtp5g && make CC=gcc-12 -j$(nproc) && modprobe udp_tunnel && insmod gtp5g.ko && lsmod | grep gtp5g'
```

### 6.2 常见现象

| 现象 | 处理 |
|---|---|
| UE 停在 PLMN 搜索 / 无法注册 | 检查 `mcc/mnc`、订阅者是否已开通、`gnbSearchList` 可达性 |
| PDU 会话建立失败 | UPF/gtp5g 未就绪；`docker logs upf` 查看 N4/N3 报错 |
| 切换未触发（`handover` 报 UE not found） | 先 `ue-list` 取正确 ue-id；确认源 gNB 上 UE 有 PDU 会话（保存了 `pduSessions`） |
| `Handover Request` 后 AMF 报错 | 检查目标 gNB 的 `nci`/`idLength` 与 TargetID 推导约定（`nci = gnbId << (36-idLength)`） |
| free5GC AMF 中途更换 `AMF-UE-NGAP-ID` | 本实现已在 Handover Command 处容错（警告并采纳新 ID）；这是 free5GC 的已知问题（UERANSIM issue #768） |
| SCTP stream 不一致告警 | 配置中保持 `ignoreStreamIds: true` |
| 端口冲突 | gnb 的 CLI/RLS/GTP 端口在容器内独立；同主机裸跑时注意 4997/2152/38412 冲突 |

## 7. Open5GS 差异点

Open5GS 的 UPF 为**用户态**（`ogstun`，无需 gtp5g 内核模块），部署更轻：

1. 部署 Open5GS（本机或容器），AMF 默认 NGAP 地址 `127.0.0.1:38412`；
2. 将 `config/gnb*.yaml` 的 `linkIp/ngapIp/gtpIp` 改为 gNB 可达地址、`amfConfigs.address` 改为 Open5GS AMF 地址；
3. 在 Open5GS WebUI 中开通同一订阅者（SUPI/K/OPc/DNN/slice 与 `ue.yaml` 一致）；
4. 其余流程（触发、验证）与 §5 完全相同。

## 8. 已知简化（运行相关）

- 切换窗口内**无 gNB 间转发**：DL 数据在 Handover Notify 前可能短暂丢失；UL 在 UE 迁移后立即可用。路径切换后 UPF 的 End Marker 会被 GTP 层记录为 `Unhandled GTP-U message type: 254`（无转发时可直接忽略）。
- 触发方式为 CLI（代替测量报告）；两 gNB 需同 PLMN/TAC（或自行扩展）。
- 不做 RAN Status Transfer / DAPS / Handover Cancel（见 `ARCHITECTURE.md` §6）。
- `ue-release` 释放 UE 后，UE 由上行数据触发原地恢复（Service Request）受**上游 UERANSIM v3.3.0 的 `selectAmf` 限制**（无 Requested NSSAI 时无法选择 AMF，未打补丁基线同样如此）；**重启 UE** 可正常恢复。详见 `REGRESSION.md` 观察 1。

## 9. 实测记录（free5GC v4.2.3 容器）

> 环境：Ubuntu 22.04 / 内核 6.8.0-138 / Docker Compose v2 / free5GC v4.2.3 images / gtp5g v0.10.2（已安装到 `/lib/modules/$(uname -r)/extra/`，`modprobe gtp5g` 可用）/ UERANSIM v3.3.0 + 本补丁（**宿主机原生构建**：cmake 3.22 / g++ 11 / libsctp-dev）。
> 本节结果使用**交付包 `deploy/` 与 `config/` 文件原样**复现（`docker-compose.n2handover.yaml` + `provision-subscriber.sh` + `run-handover.sh`）。
> 拓扑与地址同 §2（gnb1=10.100.200.101，gnb2=10.100.200.102，ue=10.100.200.121）；订阅者 `imsi-208930000000001`（sst1/sd010203，DNN internet）。

### 9.1 结果

| 验证项 | 结果 |
|---|---|
| UE 注册 + PDU 会话 | ✅ `uesimtun0 = 10.60.0.17` |
| 切换 gnb1 → gnb2 | ✅ 完整流程（Required→Request/Ack→Command→UE 迁移→Notify→源释放），约 **27 ms** |
| 反向切换 gnb2 → gnb1 | ✅ 同样完整（验证可重复切换与陈旧上下文处理） |
| 第三次切换 gnb1 → gnb2 | ✅ |
| 源/目标 `ue-list` | ✅ 切换后源侧清空、目标侧出现（`ue-id 1`） |
| AMF 侧 `AMF-UE-NGAP-ID` | free5GC 为每次切换的目标 UE 分配新 ID（1→2→3→4）；本实现按 RAN-UE-NGAP-ID 定位并采纳新 ID（源侧 Handover Command 仍用源 ID） |
| 数据面（切换后） | ✅ `ping -I uesimtun0 10.100.200.1` 切换前后各 0% 丢包 |
| 数据面路径 | ✅ `tcpdump udp port 2152`：切换后仅目标 gNB 有双向 GTP（源 gNB 0 包） |

### 9.2 关键日志（单次切换摘录）

```
--- gnb1 (source) ---
[ngap] N2 handover: Handover Required sent for UE[1] towards gNB[id 2]
[ngap] N2 handover: Handover Command received, forwarding the handover command to UE[1]
[rrc]  N2 handover: sending RRC Reconfiguration (handover command) to UE[1]
[ngap] UE Context Release Command received            (5GC 路径切换后释放源侧)

--- gnb2 (target) ---
[ngap] N2 handover: Handover Request received from AMF[2]
[ngap] N2 handover: Handover Request accepted for UE(sti[572122842734737677]), 1 session(s) admitted, 0 rejected
[rrc]  N2 handover: handover confirm (RRC Reconfiguration Complete) received from UE[1]
[ngap] N2 handover: UE[1] appeared on the target cell (sti[572122842734737677])
[ngap] N2 handover: Handover Notify sent for UE[1]

--- ue ---
[rrc] N2 handover: serving cell changed from cell[1] to cell[2] (plmn[208/93] tac[1])
[rrc] N2 handover: sending RRC Reconfiguration Complete to the target cell
[nas] N2 handover: tracking area unchanged, no mobility registration update required
```

### 9.3 部署时踩到的两个坑（已规避）

1. **静态 IP 与 Docker 动态分配冲突**：docker 会从子网低位顺序分配动态地址（核心网容器占用到 `.12` 左右），因此 gNB/UE 的静态地址请使用高位（如 `.101/.102/.121`），否则报 `Address already in use`。
2. **free5GC WebUI 订阅者 `SmPolicyData` 键格式**：`smPolicySnssaiData` 的键必须是 `sst(两位十六进制)+sd`，即 `sst=1, sd=010203 → "01010203"`；否则 PCF 报 `Can't find UE SM Policy Data in UDR`，PDU 会话建立失败。`deploy/provision-subscriber.sh` 已按此格式提供。

## 10. Open5GS / docker_open5gs VoNR 实测记录（含 IMS 通话中 N2 切换）

> 目的：① 在第二套标准核心网（Open5GS）上验证 N2 handover 兼容性；
> ② 作为下游 IMS 任务的验收场景，验证**通话中切换**的连续性（U1′：通用能力，无 IMS 专用代码）。
> 环境：docker_open5gs `sa-vonr-deploy.yaml`（Open5GS + Kamailio/pyHSS IMS，PLMN 001/01，TAC 1，SST 1），
> UERANSIM 使用 **n2handover + ims 补丁的合并构建**（原生或容器均可）。
> 完整步骤与资产见 **`deploy/open5gs/README.md`**；本节只记录结果与要点。

### 10.1 测试床关键适配（3 处，脚本 `deploy/open5gs/tweaks/apply-open5gs-tweaks.sh` 幂等应用）

1. **I-CSCF**：单 S-CSCF 直连（`SCSCF_ADDR`），绕过 Kamailio↔pyHSS 的 Diameter LIR/LIA 解析差异；
2. **P-CSCF**：关闭 `WITH_IPSEC` 与 `listen=tcp`。原因：`IPSEC_FORWARD_TRYTCP` 会对未做 IPSec 的 UE
   发 TCP（实测源端口 5100）→ 408；且该 Kamailio 6.2.0-dev1 构建在有 TCP 监听时会以 TCP 转发 MT 请求；
3. **PCF**：`qos_profiles`（`qosVoNR`→5QI 5）与 IMS 会话 `pcc_rule`（否则 N5 授权 403→REGISTER 412）。

以上均为**测试床环境适配**（不改 5GC/IMS 协议行为，也不改本补丁），细节与排错见 `deploy/open5gs/README.md` §4/§6。

### 10.2 结果（2026-09-29）

| 验证项 | 结果 |
|---|---|
| UE 接入 + 双 PDU 会话（internet + ims） | ✅ 两 UE 均成功 |
| IMS 注册（REGISTER 200 OK） | ✅ 两 UE，expires=300 |
| VoNR 通话建立（UE1→UE2，自动应答） | ✅ 双方 `callState=CONFIRMED`，rtpengine 双向 RTP |
| N2 切换（UE1：gNB1→gNB2） | ✅ 通话保持 CONFIRMED；事件序列完整 |
| N2 切换（UE1：gNB2→gNB1 回切） | ✅ 通话保持 CONFIRMED |
| **RTP 缺口（两次切换窗口内）** | ✅ 双向、两 UE 最大包间隔 **39.8–40.9 ms**，>60 ms 间隔 **0**（75 s 抓包） |
| 事件日志相关性 | ✅ 每次切换源/目标 gNB 共享同一 `ho_id`，阶段序列完整（见下） |

单次切换事件序列（JSONL，宿主机 `deploy/open5gs/ho-events/<gnb>/`）：

```
source: HO_REQUIRED_SENT → HO_COMMAND_RECEIVED → RRC_RECFG_SENT → UE_CTX_RELEASE_RECEIVED
target: HO_REQUEST_RECEIVED → HO_ACK_SENT → RRC_RECFG_COMPLETE_RECEIVED → HO_NOTIFY_SENT
```

证据摘要：`deploy/open5gs/evidence/ims-handover-summary.txt`（通话状态 + 缺口分析 + 事件相关性）。

### 10.3 测量与复现要点

- **RTP 测量点**：在 **rtpengine 容器的网络命名空间**内抓包（旁路容器），可同时看到两 UE 的上下行；
  UE 容器内 `tcpdump` 看不到 TUN 上的本机媒体流（AF_PACKET 不覆盖该路径），脚本已内置处理。
- **一键验收**：`deploy/open5gs/run-ims-test.sh --start`（自动识别 ue-id、建立通话、双向切换、分析与相关性输出）。
- Open5GS 与 free5GC 的 N2 切换流程（`docs/RUN.md` §5）**完全一致**；本节未发现任何 Open5GS 特有的实现差异
  （AMF 同样在路径切换后释放源侧、目标侧采用新分配的 AMF-UE-NGAP-ID，本实现按 RAN-UE-NGAP-ID 匹配）。

## 11. free5GC + IMS 实测记录（方案 L，与 Open5GS 对比）

> 环境：free5GC v4.2.3（精简服务集 `db nrf amf ausf udm udr smf upf pcf webui` + **`nssf`**）
> + docker_open5gs IMS 组件栈（`10.100.200.41–48`，P-CSCF `.47`），PLMN 001/01；
> UERANSIM（n2handover+ims 合并构建）两 gNB 两 UE；**N5/RX 关闭**（验收不需要 QoS 授权）。
> 资产与步骤：`deploy/free5gc-ims/README.md`；执行脚本共用 `deploy/open5gs/run-ims-test.sh`（v3）。

### 11.1 结果（10 次往返 = 20 次切换，与 Open5GS 基线同协议）

| 指标 | free5GC | Open5GS 基线 |
|---|---|---|
| 切换 / 通话保持 | **20 / 20 `CONFIRMED`** | 20 / 20 `CONFIRMED` |
| RTP 缺口 max（ue1 DL / UL） | **41.0 / 40.6 ms** | 40.9 / 41.2 ms |
| RTP 缺口 max（ue2 对照 DL / UL） | 40.6 / 40.9 ms | 41.3 / 40.9 ms |
| >60 ms 中断 | **0** | 0 |
| prep（`REQ→REQ_RECV`） | 21–27 ms | 11–13 ms |
| 空口重配 / 执行 | 0–1 ms / 0–1 ms | 0–1 ms / 0–1 ms |
| 源侧释放（`NOTIFY→CTX_REL`） | 207–219 ms | 501–508 ms |

证据：`deploy/free5gc-ims/evidence/{free5gc-ims-handover-summary.txt, free5gc-handovers.csv,
free5gc-rtp.txt.gz, compare-open5gs-free5gc.txt}`。

**结论**：业务连续性在两套独立核心网上**等价**（无 >60 ms 中断）；控制面时序差异属两套 AMF/SMF
实现行为（free5GC 准备往返约 2×、源侧释放约 2.4× 更快），与 N2 切换实现（本补丁）无关。

### 11.2 复现要点与坑（详见 `deploy/free5gc-ims/README.md` §5）

1. free5GC 需带 **`nssf`**（AMF 选 SMF 要经 NRF 查 NSSF），否则 PDU 会话请求持续 T3580 重传；
2. **不要带着曾重传的会话进入测试**：重复建立会触发 `Cause_REL_DUE_TO_DUPLICATE_SESSION_ID`
   → UPF 规则被拆除（现象：IMS REGISTER 到不了 P-CSCF）→ **重启 UE** 即可干净恢复；
3. UPF MASQUERADE 下按**媒体端口**（50002/50003）抓包/分类（脚本 v3 已实现，NAT/非 NAT 通用；
   Open5GS 基线已同口径重析，结果与 v2 一致）；
4. ePCO 正常下发（`pcscf=10.100.200.47 (EPCO)`）；UE 配置中的静态 `ims.pcscf` 仅兜底。


