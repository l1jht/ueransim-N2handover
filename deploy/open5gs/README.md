# Open5GS / docker_open5gs VoNR 测试床（N2 切换 + IMS 通话连续性）

本目录提供在 **docker_open5gs（sa-vonr-deploy）** 上运行 N2 切换验收的配套资产：
它同时承担两个目的：

1. **Open5GS 兼容性验收**：验证 N2 handover 功能在标准 Open5GS 5GC 上可用（与 free5GC 并列的第二套核心网）；
2. **IMS 通话连续性验收**（下游任务 U1′）：UE1 与 UE2 建立 VoNR 通话后，对通话中的 UE1 执行
   N2 切换（gNB1↔gNB2 双方向），验证通话保持且 RTP 无中断。

> 说明：本目录中的所有脚本只做**测试床编排**，不含任何针对 IMS/SIP 的功能性代码；
> N2 handover 能力本身与 IMS 无关（见 `docs/ARCHITECTURE.md` 与 `docs/RUN.md`）。

---

## 1. 实测环境

| 组件 | 版本 / 说明 |
|---|---|
| 主机 | Ubuntu 22.04 LTS（amd64），Docker ≥ 22.0.5，docker compose ≥ 2.14（实测 v5.5.1） |
| 核心网仓库 | `herlesupreeth/docker_open5gs`（`sa-vonr-deploy.yaml`），Open5GS/Kamailio 镜像由仓库固定提交构建 |
| Kamailio | 6.2.0-dev1（`docker_kamailio`，`ims_base` 构建，内部编号 987459） |
| Open5GS 组件 | `docker_open5gs` 镜像（含 dm_open5gs + nghttp2 的 P-CSCF N5 支持） |
| PLMN / 切片 | MCC 001 / MNC 01，TAC 1，SST 1（无 SD），IMS 域 `ims.mnc001.mcc001.3gppnetwork.org` |
| 网络 | `docker_open5gs_default` 172.22.0.0/24；AMF 172.22.0.10、P-CSCF 172.22.0.21、rtpengine 172.22.0.16 |
| UERANSIM 容器 | gNB1 172.22.0.91、gNB2 172.22.0.92、UE1 172.22.0.93、UE2 172.22.0.94 |
| 订阅者 | `imsi-001010000000001` / MSISDN 9076543210、`imsi-001010000000002` / MSISDN 9076543211；Ki `8baf…6862`，OPc `8E27…405D` |

**实测备注（仅环境差异，不影响结论）**

* 本次运行的 `mongo` 使用本地已有的 `mongo:4.4`（compose override 覆盖 `mongo:6.0`），
  因为实验网络内 `mongo:6.0` 拉取速度过慢；Open5GS HSS/USS 数据在 4.4 上工作正常。
  正常网络环境下建议按仓库默认使用 `mongo:6.0`。
* UERANSIM 二进制必须是**同时包含 n2handover 与 IMS 补丁**的构建（
  `UERANSIM_BUILD_DIR` 指向该构建目录）；若只做 Open5GS 兼容性验收（无 IMS），
  仅需 n2handover 补丁。

---

## 2. 目录内容

| 文件 | 作用 |
|---|---|
| `docker-compose.ueransim.yaml` | UERANSIM 侧 compose 覆盖文件（4 个容器 + `ho-events` 挂载） |
| `gnb1.yaml` / `gnb2.yaml` | 两个 gNB 配置（gNB ID 1/2，NCI `0x10`/`0x20`） |
| `ue1.yaml` / `ue2.yaml` | 两个 UE 配置（双 PDU 会话 internet+ims，IMS 客户端端口 5061/5062、媒体端口 50002/50003） |
| `provision.sh` | 开户脚本：Open5GS HSS（`open5gs-dbctl`）+ pyHSS（REST） |
| `run-ims-test.sh` | **验收脚本**（v3）：起 UE → 建立通话 → rtpengine 侧按媒体端口抓 RTP → `-n` 次往返 N2 切换 → 逐次缺口分析 + 控制面耗时 + 事件相关性（同一脚本也用于 free5GC 运行：`../free5gc-ims/README.md`） |
| `tweaks/apply-open5gs-tweaks.sh` | 对 docker_open5gs 仓库应用 3 处环境适配（见第 4 节） |

---

## 3. 部署步骤

### 3.1 准备 docker_open5gs 与补丁

```bash
git clone https://github.com/herlesupreeth/docker_open5gs
cd docker_open5gs

# 应用测试床适配（I-CSCF 单 S-CSCF 直连、P-CSCF 关闭 IPSec/TCP、PCF QoS/PCC 配置）
/<deliver>/deploy/open5gs/tweaks/apply-open5gs-tweaks.sh .

# 将本目录复制到 docker_open5gs 的 n2handover/ 子目录（compose 相对路径依赖该布局）
cp -r /<deliver>/deploy/open5gs n2handover
mkdir -p n2handover/ho-events/gnb1 n2handover/ho-events/gnb2

# 启动所需镜像（预构建镜像方式；也可本地构建）
for i in docker_open5gs docker_kamailio docker_pyhss docker_mysql docker_dns docker_rtpengine; do
    docker pull ghcr.io/herlesupreeth/$i:master && docker tag ghcr.io/herlesupreeth/$i:master $i
done
```

`.env` 使用仓库默认值即可（PLMN 001/01、UE 网段 192.168.100.0/24 与 192.168.101.0/24）。

### 3.2 启动核心网 + IMS 容器

```bash
cd docker_open5gs
docker compose -f sa-vonr-deploy.yaml up -d \
    mongo webui nrf scp ausf udr udm smf upf amf pcf bsf nssf dns rtpengine mysql pyhss icscf scscf pcscf smsc
```

> 若沿用 mongo:4.4（见 1 节备注），追加一个 override：
> `services: { mongo: { image: mongo:4.4 } }`，并用 `-f` 一起传入。

### 3.3 开户

```bash
cd docker_open5gs
/<deliver>/deploy/open5gs/provision.sh
```

脚本内容：对两个 IMSI 通过 `open5gs-dbctl` 添加 `internet`/`ims` 两个 APN；
再通过 pyHSS REST（注意其 API 为 **PUT 创建 + GET `/xxx/list` 查询**）写入 APN、AUC、
SUBSCRIBER、IMS SUBSCRIBER（S-CSCF 指向 `sip:scscf.ims.mnc001.mcc001.3gppnetwork.org:6060`）。

### 3.4 运行 N2 切换 / IMS 连续性验收

```bash
cd docker_open5gs
export UERANSIM_BUILD_DIR=/path/to/UERANSIM/build      # 含 n2handover(+ims) 补丁的构建
export COMPOSE_DIR=$PWD
export COMPOSE_FILES="-f sa-vonr-deploy.yaml -f n2handover/docker-compose.ueransim.yaml"
export HO_EVENTS_DIR=$PWD/n2handover/ho-events

n2handover/run-ims-test.sh --start
```

脚本流程（每一步都有中文/英文输出）：

1. 启动 gNB1/gNB2/UE1 → 等待 UE1 的 PDU 会话与 IMS 注册，读出 UE1 在 gNB1 上的 `ue-id`；
2. 启动 UE2 → 等待会话与 IMS 注册；
3. UE1 呼叫 UE2（UE2 自动应答），双方 `callState=CONFIRMED`；
4. 在 **rtpengine 网络命名空间**内抓包（旁路容器），可同时看到两个 UE 的 RTP；
5. 触发 UE1 的 N2 切换 gNB1→gNB2，再切回 gNB2→gNB1；
6. 输出：通话状态、媒体计数、**RTP 缺口分析**（最大间隔 / >60ms 间隔数）与
   **ho-events 相关性**（同一 `ho_id` 在源/目标 gNB 的事件序列）。

无 IMS 的纯 Open5GS 功能验收可直接使用仓库既有方式（`docs/RUN.md` 第 5 节命令），
本目录脚本不影响该流程。

---

## 4. docker_open5gs 适配说明（`tweaks/apply-open5gs-tweaks.sh`）

三处改动均为**测试床环境适配**，不改变网元协议行为，且脚本幂等：

1. **I-CSCF：单 S-CSCF 直连、绕过 Diameter LIR**
   Kamailio I-CSCF 会通过 Cx LIR 向 HSS 查询用户的 S-CSCF，而 pyHSS 的 LIA 封装与
   Kamailio 解析不一致（不同开源项目实现差异），导致 `500 Server error on LIR select …`。
   修改 `icscf/icscf.cfg`、`icscf/icscf_init.sh`、`icscf/kamailio_icscf.cfg`：定义
   `SCSCF_ADDR` 并让 `route[initial_request]` 直接按 IP 转发到唯一 S-CSCF，
   `failure_route[initial_request_failure]` 去除多 S-CSCF 故障转移。
   该做法与同实验室的《Open5GS_IMS》部署笔记一致。

2. **P-CSCF：关闭 IPSec 与 SIP/TCP 监听**
   * `WITH_IPSEC` 开启时，P-CSCF 的 `route[MT]` 会对 `ipsec_clients` 表中的 UE 执行
     `ipsec_forward(..., IPSEC_FORWARD_FLAGS=897)`，其中含 `IPSEC_FORWARD_TRYTCP`：
     对未建立 IPSec 的 UE（UERANSIM IMS 客户端不实现 IPSec）会尝试 TCP 连接（源端口 5100），
     必然失败 → 408 → 呼叫被拒。关闭 `WITH_IPSEC` 后 MT 请求走普通 UDP。
   * 该 Kamailio 构建在存在 SIP/TCP 监听时会把 MT 请求以 **TCP** 发往 UE（实测持续复现），
     而测试 UE 只监听 UDP；注释 `listen=tcp:PCSCF_IP:5060` 后强制 UDP。
   （COTS 手机走 IPSec 场景不受影响；如需保留，可仅对本测试的 UE 使用无 IPSec 的 P-CSCF 配置。）

3. **PCF：`qos_profiles` 与 IMS 会话策略**
   P-CSCF 在 REGISTER/INVITE 时通过 N5 向 PCF 请求 QoS 授权，携带
   `qosReference="qosVoNR"`；PCF 若未配置该参考值则回 `403`，P-CSCF 转成
   `412 Register N5 QoS authorization failed`。在 `pcf/pcf.yaml` 增加：

   * `qos_profiles: [{reference: qosVoNR, qos_index: 5}]`（5QI 5，信令/非 GBR）；
   * `policy`（SUPI 段 001010000000001–001010000000002）：`internet`(5QI 9) 与
     `ims`(5QI 5) 两个会话，并为 `ims` 配置 `pcc_rule`（index 5 + 宽松 UDP 流描述），
     避免 PCF 因 “No PCC Rule in DB” 拒绝 N5 授权。

   修改配置后需 `restart pcf`，并且**在 PCF 重启后让 UE 重新建立 PDU 会话**
   （PCF 的 SM 策略关联是内存态），否则 N5 查询会 404。

---

## 5. 实测结果（2026-09-29）

| 项目 | 结果 |
|---|---|
| UE 接入 / 双 PDU 会话 | ✅ 两 UE 均建立 internet + ims 会话 |
| IMS 注册 | ✅ 两 UE REGISTER 200 OK（expires=300） |
| 通话 | ✅ UE1→UE2 CONFIRMED，rtpengine 双向 RTP（20ms 包间隔） |
| N2 切换 | ✅ UE1 双向切换（gNB1→gNB2→gNB1），两次通话均保持 CONFIRMED |
| RTP 缺口（切换期间） | ✅ 双向、两 UE 最大间隔 **39.8–40.9 ms**，>60ms 间隔 **0** |
| ho-events 相关性 | ✅ 每次切换源/目标 gNB 共享同一 `ho_id`，阶段序列完整 |

事件序列（每次切换）：

```
source: HO_REQUIRED_SENT → HO_COMMAND_RECEIVED → RRC_RECFG_SENT → UE_CTX_RELEASE_RECEIVED
target: HO_REQUEST_RECEIVED → HO_ACK_SENT → RRC_RECFG_COMPLETE_RECEIVED → HO_NOTIFY_SENT
```

事件文件位置：`n2handover/ho-events/<gnb>/<gNB 名称>.ho-events.jsonl`
（即容器内 `/ueransim/logs/`），始终开启、无需配置，详见 `docs/MEASUREMENT.md`。

---

## 6. 常见问题

| 现象 | 处理 |
|---|---|
| 呼叫被 `500 No alternate SCSCF available` / `Server error on LIR…` 拒绝 | 未应用 I-CSCF 改动或 I-CSCF 未重启 |
| REGISTER 返回 `412 Register N5 QoS authorization failed` | PCF 缺少 `qos_profiles`/`policy`，或 PCF 重启后 UE 未重建 PDU 会话 |
| 呼叫超时（408）且 UE 未收到 INVITE | P-CSCF 的 IPSec/TCP 适配（第 4.2 节）；抓包可见 P-CSCF→UE 的 TCP SYN |
| UE 侧 `tcpdump` 抓不到媒体 | TUN 上的本机收发包对 AF_PACKET 不可见；在 **rtpengine** 侧抓包（脚本已采用） |
| 呼叫建立后立即失败/无媒体 | 确认两 UE 均已 IMS 注册；`rtpengine` 容器已启动 |
| pyHSS 开户 404 | pyHSS API 为 PUT + `/xxx/list`，使用本目录 `provision.sh`（不要用 POST 形式） |
