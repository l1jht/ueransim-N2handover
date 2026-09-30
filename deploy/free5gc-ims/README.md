# free5GC + IMS 测试床（N2 切换 + IMS 通话连续性，方案 L）

本目录提供在 **free5GC v4.2.3** 上运行"IMS 通话中 N2 切换"验收的配套资产（与
`../open5gs/` 对等）。设计原则（方案 L）：**不动 free5GC 的部署形态**（沿用现有 compose 与网络），
只做"加一个 `ims` DNN + 开户"的最小增量；IMS 侧**复用 docker_open5gs 的组件栈**（同 Open5GS 运行），
**N5/RX 关闭**（本验收不需要 QoS 授权；也避开 UERANSIM 未实现的 PDU Session Resource Modify 路径）。

> 对照记录：Open5GS 版见 `../open5gs/README.md`；过程与排错记录见仓库根 `docs/testlogs.md`。

---

## 1. 实测环境（2026-09-30）

| 组件 | 说明 |
|---|---|
| free5GC | v4.2.3 镜像；**精简服务集**：`db nrf amf ausf udm udr smf upf pcf webui` + **`nssf`**（见 §5 坑 1） |
| 网络 | 沿用 free5GC compose 网络 `10.100.200.0/24`（本项目目录名决定网络名前缀） |
| IMS | docker_open5gs 组件：`dns rtpengine mysql pyhss icscf scscf pcscf smsc`（`10.100.200.41–.48`，P-CSCF `.47`） |
| UERANSIM | `gnb1/gnb2/ue1/ue2` 容器（`10.100.200.131–.134`），n2handover+ims 合并构建 |
| PLMN / 切片 | 001/01、TAC 1、sst1/sd010203；UE 双会话 `internet` + `ims`（ims 池 `192.168.101.0/24`） |
| 订阅者 | `imsi-001010000000001/2`（Ki/OPc 同 Open5GS 运行）；pyHSS 侧同款开户 |

## 2. 目录内容

| 文件 | 作用 |
|---|---|
| `docker-compose.ueransim.yaml` | UERANSIM 侧 overlay（两 gNB + 两 UE，`.131–.134`） |
| `docker-compose.ims.yaml` | IMS 8 服务（接入 free5GC 网络，固定 IP `.41–.48`） |
| `gnb1/gnb2/ue1/ue2.yaml` | free5GC 版 UERANSIM 配置（PLMN 001/01、双会话、静态 `ims.pcscf` 兜底 + ePCO） |
| `env.free5gc` | IMS 侧 `.env`（PLMN 001/01、IP 指向 `10.100.200.4x`、`UPF_IP=10.100.200.8`、`UE_IPV4_IMS`） |
| `tweaks/apply-free5gc-ims-tweaks.sh` | 幂等适配（对 free5GC checkout：PLMN 001/01 + `ims` DNN + UPF 静态 IP；对 docker_open5gs checkout：保持 N5 关闭） |
| `provision-free5gc-ims.sh` | 开户（free5GC WebUI：双 DNN + **SmPolicyData**；pyHSS：APN/AUC/SUBSCRIBER/IMS_SUBSCRIBER） |
| `evidence/` | 实测证据（汇总 + 逐次切换 CSV + 双核对比） |

> 验收执行脚本共用 `../open5gs/run-ims-test.sh`（v3：`-n` 往返、按**媒体端口**抓包/分类、逐次缺口与
> 控制面耗时统计）；free5GC 运行时以环境变量切换容器名与网络：

```bash
UE1=ue1 UE2=ue2 GNB1=gnb1 GNB2=gnb2 \
COMPOSE_DIR=<free5gc-compose-dir> \
COMPOSE_FILES="-f docker-compose.yaml -f docker-compose.free5gc-ims.yaml" \
RUN_DIR=<结果目录> HO_EVENTS_DIR=<compose-dir>/ho-events \
../open5gs/run-ims-test.sh -n 10 -w 8 --start
```

## 3. 部署步骤（浓缩）

1. **free5GC 侧**：复制 free5GC compose 环境到工作目录（不动原环境）→ 执行
   `tweaks/apply-free5gc-ims-tweaks.sh <compose-dir>`（PLMN 001/01、AMF/SMF/UPF 加 `ims` DNN、
   SMF `pcscf.ipv4=10.100.200.47`、UPF 静态 `10.100.200.8`）→ 将 `gnb1/gnb2/ue1/ue2.yaml` 复制为
   `config/ims-{gnb1,gnb2,ue1,ue2}.yaml`、`docker-compose.ueransim.yaml` 复制为
   `docker-compose.free5gc-ims.yaml` → `mkdir -p ho-events/{gnb1,gnb2}`。
2. **IMS 侧**：docker_open5gs checkout（先执行 `../open5gs/tweaks/apply-open5gs-tweaks.sh`）→ 再执行
   `tweaks/apply-free5gc-ims-tweaks.sh <docker_open5gs-dir>`（保持 N5 关闭）→ 用 `env.free5gc` 覆盖 `.env`
   → 复制 `docker-compose.ims.yaml` 到该 checkout。
3. **启动**：
   ```bash
   # free5GC
   cd <free5gc-compose-dir>
   export UERANSIM_BUILD_DIR=/path/to/UERANSIM/build
   docker compose -f docker-compose.yaml -f docker-compose.free5gc-ims.yaml up -d \
       db free5gc-nrf free5gc-amf free5gc-ausf free5gc-udm free5gc-udr free5gc-smf \
       free5gc-upf free5gc-pcf free5gc-webui free5gc-nssf
   # IMS（join 到 free5GC 网络：网络名 = <free5gc compose 项目名>_privnet）
   cd <docker_open5gs-dir>
   F5GC_NETWORK=<free5gc-compose-dir 名>_privnet docker compose -f docker-compose.ims.yaml up -d \
       dns rtpengine mysql pyhss icscf scscf pcscf smsc
   ```
4. **开户**：`provision-free5gc-ims.sh http://127.0.0.1:5000 http://127.0.0.1:8080`
5. **起 UE 并验收**：见 §2 的 `run-ims-test.sh` 命令（`--start` 会先起 `gnb1/gnb2/ue1`、读 ue1 的
   ue-id、再起 `ue2`，随后通话 + 双向切换 + 分析）。

## 4. 实测结果（2026-09-30，与 Open5GS 基线同协议）

| 指标 | free5GC | Open5GS 基线 |
|---|---|---|
| 10 次往返（20 次切换）/ 通话保持 | **20 / 20 CONFIRMED** | 20 / 20 CONFIRMED |
| RTP 缺口 max（ue1 DL / UL） | **41.0 / 40.6 ms** | 40.9 / 41.2 ms |
| RTP 缺口 max（ue2 对照 DL / UL） | 40.6 / 40.9 ms | 41.3 / 40.9 ms |
| >60 ms 中断 | **0** | 0 |
| prep（`HO_REQUIRED_SENT→HO_REQUEST_RECEIVED`） | 21–27 ms | 11–13 ms |
| 空口重配（`RRC_RECFG_SENT→…COMPLETE_RECEIVED`） | 0–1 ms | 0–1 ms |
| 执行（`HO_COMMAND_RECEIVED→HO_NOTIFY_SENT`） | 0–1 ms | 0–1 ms |
| 源侧释放（`HO_NOTIFY_SENT→UE_CTX_RELEASE_RECEIVED`） | 207–219 ms | 501–508 ms |

结论：**RTP 层面的通话连续性在两套核心网上等价**（均无 >60 ms 中断）；控制面时序差异来自两套
AMF/SMF 实现（free5GC 准备往返约 2×，源侧释放约 2.4× 更快）。证据见 `evidence/`。

## 5. 排错记录（本次实际踩到，供复现参考）

1. **free5GC 必须带 `nssf`**：AMF 在 SMF 选择时会通过 NRF 查询 NSSF（`Nnssf_NSSelection`）；
   精简掉 `nssf` 后表现为 `AMF can not select an NSSF Instance by NRF`，UE 的 PDU 会话请求
   持续 T3580 重传（2016-09 指南 compose 里同样带 `free5gc-nssf`）。**处置：回补 `nssf`。**
2. **T3580 重传会造成"重复会话"**：nssf 缺失期间 UE 每次重传都被 SMF 处理，恢复后重复的建立请求
   触发 `Cause_REL_DUE_TO_DUPLICATE_SESSION_ID`，SMF 释放首建会话 → UPF 拆除对应规则 → gNB 仍用旧
   TEID 上行被丢弃（现象：IMS REGISTER 到不了 P-CSCF）。**处置：重启 UE，让会话一次干净建立**
   （本次重启后 REGISTER 立即 200 OK）。测试前务必确认**没有发生过会话重传**。
3. **UPF MASQUERADE 下的媒体抓包**：UE↔rtpengine 两个方向都经 UPF NAT（地址变 `10.100.200.8`），
   但 **UE 侧媒体端口被保留**；因此 `run-ims-test.sh` v3 改为**按媒体端口（50002/50003）抓包与分类**
   ——该口径对 NAT/非 NAT 环境均成立（Open5GS 基线亦用同口径重析，结果一致）。
4. **ePCO 生效**：UE 日志 `IMS session bound [psi=2, local=192.168.101.x, pcscf=10.100.200.47 (EPCO)]`
   ——SMF `dnnInfos[ims].pcscf.ipv4` 正常下发；UE 配置中的静态 `ims.pcscf` 仅作兜底。
5. 其余沿用 Open5GS 侧经验：I-CSCF LIR 旁路、P-CSCF 关闭 IPSec 与 SIP/TCP 监听、S-CSCF MD5
   （我们的 IMS 客户端为 MD5 digest，password=Ki）。

## 6. 本期不做（边界）

N5/RX 直连（列为可选 P2；free5GC 官方尚未支持 VoNR 专用承载，且 UERANSIM 不处理
`PDUSessionResourceModify`）；防重传的会话去重（属 UERANSIM/5GC 交互的既有行为，以流程约束规避，见坑 2）。
