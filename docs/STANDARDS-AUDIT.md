# `docs/N2-handover.md` 来源与正确性审计（2026-10-01，**已联网核对原文**）

> **审计动因**：v2/v2.1 的差距分析（`docs/v2-standard-gaps.md`）与设计决策均以该文档为规范基准。
>
> **核实条件（更新）**：代理开启后已从 **ETSI 官网**下载并文本化三份被引规范（`pdftotext`）：
>
> | 规范 | 文件 | 页数 | ETSI 发布 |
> |---|---|---|---|
> | TS 38.413 | `ts_138413v181000p.pdf` | 650 | V18.10.0（2026-07） |
> | TS 23.502 | `ts_123502v181400p.pdf` | 935 | V18.14.0（2026-07） |
> | TS 38.300 | `ts_138300v181000p.pdf` | — | V18.10.0（2026-08） |
>
> **版本表核对**：文档声明的三个关键版本（38.413 V18.10.0、23.502 V18.14.0、38.300 V18.10.0）**均在 ETSI 存在**
> （ETSI 发布日期比 3GPP 版本日期晚约 1 个月，文档标注的 "2026-06（SA#112）" 与 3GPP 侧日期一致）。
> 23.501/38.401/38.423 未下载（其被引内容不在我们的实现/差距分析范围内）。
>
> 下文引用行号为下载文本（`/tmp/opencode/specs/*.txt`）行号，便于复核。

---

## 1. 逐条核对（我们实际使用的全部主张）

### 1.1 消息/IE 结构（38.413 ASN.1 原文）

| 主张 | 原文证据 | 结论 |
|---|---|---|
| Required 每会话携带转发可用性 | `HandoverRequiredTransfer ::= SEQUENCE { directForwardingPathAvailability DirectForwardingPathAvailability OPTIONAL, ... }`（L31600） | ✅ |
| Ack 携带 N3 TNL + 转发 TNL + 成功/失败列表 | `HandoverRequestAcknowledgeTransfer{dL-NGU-UP-TNLInformation, dLForwardingUP-TNLInformation OPTIONAL, securityResult OPTIONAL, qosFlowSetupResponseList, qosFlowFailedToSetupList OPTIONAL, ...}` | ✅ |
| 目标按 QoS 流表示"接受转发" | `QosFlowItemWithDataForwarding ::= SEQUENCE { qosFlowIdentifier, dataForwardingAccepted DataForwardingAccepted OPTIONAL, ... }`（L35453） | ✅ **C1 逐字成立** |
| Command 携带转发 TNL 与流转发列表 | `HandoverCommandTransfer{dLForwardingUP-TNLInformation OPTIONAL, qosFlowToBeForwardedList OPTIONAL, ...}`（L28） | ✅ |
| Command 携带"未建立会话列表（含原因）" | IE 78 `PDUSessionResourceToReleaseListHOCmd`（L25989）+ `PDUSessionResourceToReleaseItemHOCmd{pDUSessionID, handoverPreparationUnsuccessfulTransfer}` | ✅ **C4 逐字成立** |
| SM N2 信息可给"不可转发"指示 | `DataForwardingNotPossible ::= ENUMERATED { data-forwarding-not-possible }`（L30358），位于 `PDUSessionResourceSetupRequestTransfer`（IE 127，L34810） | ✅ |
| SN 经 "PDCP PDU number" 扩展头 | 38.300 §9.2.3.2.3 NOTE："The SN of forwarded PDCP SDUs is carried in the 'PDCP PDU number' field of the GTP-U extension header." | ✅ |

### 1.2 转发语义（23.502 / 38.300 原文）

| 主张 | 原文证据 | 结论 |
|---|---|---|
| 直接转发=回传 T-RAN 转发 TNL；间接=UPF 端点 | 23.502 执行步骤 1（L16962）："The SM forwarding info list includes **T-RAN SM N3 forwarding info list for direct forwarding** or **S-UPF SM N3 forwarding info list for indirect data forwarding**" | ✅（且与 free5GC/Open5GS 实测一致） |
| 源开始转发（按 QoS 流/DRB 受控） | 23.502 执行步骤 3（L16995）："The S-RAN should start forwarding of downlink data ... for QoS Flows or DRBs subject to data forwarding. This may be either direct (step 3a) or indirect forwarding (step 3b)." | ✅ |
| 目标可按**每 PDU 会话**建转发隧道并给出"接受的流" | 38.300 §9.2.3.2.3（L5983）："The target NG-RAN node **may also decide to establish a downlink forwarding tunnel for each PDU session**. In this case the target NG-RAN node provides information for which QoS flows data forwarding has been accepted and corresponding UP TNL information..." | ✅（我们=会话级 + per-flow accepted 标志） |
| **不可转发时目标不应携带转发 TNL** | 38.413 §8.4.2.2（L4468）："If the HANDOVER REQUEST message contains the Data Forwarding Not Possible IE ... the target NG-RAN node **may not include the DL Forwarding UP TNL Information IE** ... for that PDU session." | ✅ **C2 逐字成立** |
| 目标接受转发时置 `Data Forwarding Accepted` | 38.413 §8.4.2.2（L4431）："The **Data Forwarding Accepted IE if the data forwarding for the QoS flow is accepted**." | ✅ **C1 逐字成立** |
| **end marker：源必须转发给目标** | 23.502 执行步骤 10b（L17096）："the UPF (PSA) sends one or more 'end marker' packets for each N3 tunnel on the old path immediately after switching the path, **the source NG-RAN shall forward the 'end marker' packets to the Target NG-RAN**." | ✅ **C3 逐字成立** |
| 路径切换由 AMF/SMF 驱动（N2 无 Path Switch Request） | 23.502 执行步骤 10a（SMF→PSA N4 修改切换下行路径）+ 执行流程图中目标发 Handover Notify（非 Path Switch Request） | ✅ |
| 失败会话列表的使用 | 23.502 执行步骤 1（L16973）："S-RAN uses the PDU Sessions failed to be setup list and the indicated reason for failure to decide whether to proceed with the N2 Handover procedure." | ✅ **C4 逐字成立** |

### 1.3 定时器与流程（38.413 原文）

| 主张 | 原文证据 | 结论 |
|---|---|---|
| TNGRELOCprep：Required 发出启动；Command 收到停止并启动 overall | 38.413 §8.4.1.2（L4275）："Upon reception of the HANDOVER COMMAND message the source NG-RAN node shall stop the timer TNGRELOCprep and start the timer TNGRELOCoverall." | ✅ 逐字 |
| prep 超时→发起 Cancel 并忽略迟到消息 | §8.4.1.3（L4360）："If there is no response from the AMF to the HANDOVER REQUIRED message before timer TNGRELOCprep expires ..., the source NG-RAN node **should cancel the Handover Preparation procedure by initiating the Handover Cancel procedure** ... shall ignore any HANDOVER COMMAND or HANDOVER PREPARATION FAILURE received after..." | ✅（我们未实现 Cancel=文档化偏差，方向一致） |
| overall 超时→请求 AMF 释放 UE 上下文 | §8.3.3.4（L3339）："If the UE Context Release procedure is not initiated towards the NG-RAN node before the expiry of the timer TNGRELOCOverall, the NG-RAN node **shall request the AMF to release the UE context**."；"If the UE returns ... the NG-RAN node shall stop the timer TNGRELOCOverall and continue to serve the UE." | ✅ 逐字 |
| 定时器语义（§9.6） | "TNGRELOCprep: Specifies the maximum time for the Handover Preparation procedure in the source NG-RAN node." / "TNGRELOCoverall: ... protection of the overall handover procedure ..." | ✅（数值仍由实现/O&M 决定，文档表述一致） |
| 注册更新子集：跳过 4/5/10 | 23.502 执行步骤 12（L17139）："the target AMF performs only a subset of the Registration procedure, specifically **the steps 4, 5 and 10** in the Registration procedure for the context transfer between source AMF and target AMF are skipped." | ✅ **逐字（此前标"步号未核"→ 现核实）** |

## 2. 更正此前的审计结论

| 此前结论 | 更正 |
|---|---|
| "瑕疵 a"：§4.1 步骤 1 把 `Direct Forwarding Path Availability` 写成"SM N2 信息含" | **撤回**。23.502 原文（L16505）逐字："The **SM N2 info includes Direct Forwarding Path Availability** if direct data forwarding is available." + "This indication **from S-RAN** can be based on e.g. the presence of IP connectivity and security association(s)..." —— 文档忠实转述规范。 |
| "瑕疵 b"：§4.1 步骤 10 的"（上行 AN TEID）"标注 | **保留**（术语不精确）：38.413 的 Ack 字段为 `dL-NGU-UP-TNLInformation`（目标 gNB 的 **DL** N3 端点）；23.502 步骤 10a 称其为 "N3 AN Tunnel Info of T-RAN"。不影响实现（按 ASN.1 字段构造）。 |
| "版本/页码不可核" | **版本号已核实存在**；页码未逐页核对（可接受）。 |

## 3. 原文核对中发现的新增项（此前未列入）

| # | 项 | 原文证据 | 处理 |
|---|---|---|---|
| **N1** | TNGRELOCoverall 超时请求释放时，应使用专用 cause **"TNGRELOCoverall expiry"** | 38.413 无线网络层 cause 列表（L12756/12900）："TNGRELOCoverall expiry — The reason for the action is expiry of timer TNGRELOCoverall."；仓库枚举已有 `RadioNetwork_tngrelocoverall_expiry` | ✅ **已修**（commit `4e29d0e`，v2.1a） |
| **N2** | 源可在**透明容器**中按 QoS 流提出转发建议（`QosFlowInformationItem.dLForwarding = dl-forwarding-proposed`，位于 `PDUSessionResourceInformationList`，38.413 L30457/L35302/L34303），目标据此按流决定；38.413 §8.4.2.2："if the target NG-RAN node accepts the downlink data forwarding for at least one QoS flow for which the DL Forwarding IE is set to 'DL forwarding proposed', it may include the DL Forwarding UP TNL Information IE..." | 我们的透明容器为仿真载荷、不含该指示 → 属既有"容器简化"（B 类）；两核实测均接受我们无条件携带的转发 TNL | 记入差距文档（文档化，不改码） |

## 4. 结论

1. **`N2-handover.md` 在我们使用的全部层面与原文逐字一致**：消息/IE 结构、直接/间接转发语义、`DataForwardingAccepted`、`DataForwardingNotPossible`、失败会话列表、end marker 转发、TNGRELOCprep/overall 起止与到期动作、注册更新子集（4/5/10）等；
2. **此前的差距分析 C1–C4 全部被原文逐字证实**（C1/C2/C3/C4 均找到直接支撑句），v2/v2.1 的实现与验收结论**无需回退**；
3. 审计新增两项：**N1 已修**（专用 cause 值）、**N2 文档化**（容器内 per-flow 转发建议属仿真简化）；
4. 唯一保留的文档瑕疵：§4.1 步骤 10 的"（上行 AN TEID）"术语标注（不影响实现）。
