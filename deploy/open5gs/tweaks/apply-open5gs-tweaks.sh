#!/bin/bash
# Apply the docker_open5gs / Kamailio tweaks required by the VoNR N2-handover
# acceptance test (3GPP PLMN 001/01, Kamailio 6.2.0-dev1 build from ims_base,
# Open5GS pinned by docker_open5gs).
#
# The three tweaks are:
#
#  1. I-CSCF: route initial requests directly to the single S-CSCF instead of
#     asking pyHSS via Diameter LIR (Kamailio and pyHSS encode/decode the LIA
#     S-CSCF list differently, so selection fails in a single-S-CSCF lab).
#     Files: icscf/icscf.cfg, icscf/icscf_init.sh, icscf/kamailio_icscf.cfg
#
#  2. P-CSCF: disable IPSec (WITH_IPSEC) and the SIP/TCP listener.
#     - WITH_IPSEC makes the P-CSCF treat UEs as IPSec clients and push the
#       terminating INVITE over TCP (IPSEC_FORWARD_TRYTCP), which fails for
#       UEs that register without IPSec (e.g. UERANSIM's IMS client).
#     - With a TCP listener present, this Kamailio build relays mobile
#       terminated requests to the UE over TCP; the tested UEs only listen on
#       UDP, so the SIP/TCP listener is commented out.
#     File: pcscf/pcscf.cfg
#
#  3. PCF: add the QoS profile for the qosReference sent by the P-CSCF
#     ("qosVoNR") and a policy with a PCC rule for the IMS session, so that the
#     N5 QoS authorization performed during IMS REGISTER/INVITE succeeds.
#     File: pcf/pcf.yaml
#
#  4. pyHSS: the default iFC routes SIP MESSAGE to sip:smsc...:5060, but the SMSC
#     listens on 7090 - without this fix SMS never reaches the SMSC.
#     File: pyhss/default_ifc.xml
#
# Usage:  ./apply-open5gs-tweaks.sh [path-to-docker_open5gs]   (default: .)
#         (run inside the checkout, or pass the checkout path)
# Idempotent: already applied tweaks are reported and skipped.
set -e

ROOT=${1:-.}
cd "$ROOT"

[ -f sa-vonr-deploy.yaml ] || [ -f sa-deploy.yaml ] || {
    echo "error: $PWD does not look like a docker_open5gs checkout"; exit 1;
}

echo "== 1. I-CSCF: bypass Diameter LIR, route directly to the S-CSCF =="
python3 - <<'PY'
from pathlib import Path

# 1a. icscf.cfg -- definitions used by kamailio_icscf.cfg
p = Path("icscf/icscf.cfg")
t = p.read_text()
anchor = '#!define HOSTNAME "icscf.IMS_DOMAIN"'
add = anchor + '\n#!define SCSCF_URI "sip:scscf.IMS_DOMAIN:6060"\n#!define SCSCF_ADDR "sip:SCSCF_IP:6060"'
if "SCSCF_ADDR" in t:
    print("  icscf/icscf.cfg: already applied")
else:
    assert anchor in t, "anchor not found in icscf/icscf.cfg"
    p.write_text(t.replace(anchor, add, 1))
    print("  icscf/icscf.cfg: SCSCF_ADDR definition added")

# 1b. icscf_init.sh -- render SCSCF_IP into the container config
p = Path("icscf/icscf_init.sh")
t = p.read_text()
anchor = "sed -i 's|ICSCF_IP|'$ICSCF_IP'|g' /etc/kamailio_icscf/icscf.cfg"
add = anchor + "\nsed -i 's|SCSCF_IP|'$SCSCF_IP'|g' /etc/kamailio_icscf/icscf.cfg"
if "s|SCSCF_IP|" in t:
    print("  icscf/icscf_init.sh: already applied")
else:
    assert anchor in t, "anchor not found in icscf/icscf_init.sh"
    p.write_text(t.replace(anchor, add, 1))
    print("  icscf/icscf_init.sh: SCSCF_IP substitution added")

# 1c. kamailio_icscf.cfg -- initial_request + failure route
p = Path("icscf/kamailio_icscf.cfg")
t = p.read_text()
if "Bypassing LIR" in t:
    print("  icscf/kamailio_icscf.cfg: already applied")
else:
    old_route = '''route[initial_request]
{
#\t$avp(prefix)="+";
#\t$ru= $(ru{s.rm,$avp(prefix)});
\txlog("$$ru => $ru\\n");
\tI_perform_location_information_request("LIR_REPLY", "0");
}'''
    new_route = '''route[initial_request]
{
#\t$avp(prefix)="+";
#\t$ru= $(ru{s.rm,$avp(prefix)});
\txlog("$$ru => $ru\\n");
\t# Bypass Diameter LIR - route directly to SCSCF by IP (avoid DNS dependency)
\t# In single S-CSCF setup, LIR is unnecessary and prone to AVP parsing issues
\t$du = SCSCF_ADDR;
\txlog("L_DBG", "Bypassing LIR, routing directly to $du\\n");
\tt_on_reply("initial_request_reply");
\tt_on_failure("initial_request_failure");
\tif (!t_relay()) {
\t\tt_reply("500","Error forwarding towards S-CSCF");
\t}
}'''
    old_fail = '''failure_route[initial_request_failure]
{
\txlog("L_DBG", "Enter initial request failure block");
\tif (t_check_status("(408)")){
\t\txlog("L_DBG", "Got a failure for initial request");
\t\tif (I_scscf_select("1")) {
\t\t\tt_on_reply("initial_request_reply");
\t\t\tt_on_failure("initial_request_failure");
\t\t\tif (!t_relay()) {
\t\t\t\tt_reply("500","Error forwarding towards next S-CSCF");
\t\t\t\tbreak;
\t\t\t}
\t\t\tbreak;
\t\t} else {
\t\t\tt_reply("500", "Server error on LIR select next S-CSCF");
\t\t\tbreak;
\t\t}
\t} else {
\t\txlog("L_DBG", "dropping scscf list on  initial request failure");
\t\tI_scscf_drop();
\t}
\tbreak;
}'''
    new_fail = '''failure_route[initial_request_failure]
{
\txlog("L_DBG", "Enter initial request failure block");
\tif (t_check_status("(408)")){
\t\tt_reply("500", "No alternate SCSCF available");
\t} else if (t_check_status("([5-6][0-9][0-9])")){
\t\tt_reply("500", "SCSCF returned error");
\t} else {
\t\txlog("L_DBG", "Non-recoverable failure on initial request");
\t}
}'''
    for old, new in ((old_route, new_route), (old_fail, new_fail)):
        assert old in t, "block not found in icscf/kamailio_icscf.cfg"
        t = t.replace(old, new, 1)
    p.write_text(t)
    print("  icscf/kamailio_icscf.cfg: LIR bypass applied")
PY

echo "== 2. P-CSCF: disable IPSec and the SIP/TCP listener =="
python3 - <<'PY'
import re
from pathlib import Path
p = Path("pcscf/pcscf.cfg")
t = p.read_text()
for old, new, label in (
    ("#!define WITH_IPSEC\n", "##!define WITH_IPSEC\n", "WITH_IPSEC"),
    ("listen=tcp:PCSCF_IP:5060\n", "#listen=tcp:PCSCF_IP:5060\n", "SIP/TCP listener"),
):
    if re.search(r"^" + re.escape(new.rstrip("\n")) + r"\s*$", t, re.M):
        print(f"  pcscf/pcscf.cfg: {label} already disabled")
    elif re.search(r"^" + re.escape(old.rstrip("\n")) + r"\s*$", t, re.M):
        t = re.sub(r"^" + re.escape(old.rstrip("\n")) + r"\s*$", new.rstrip("\n"), t, count=1, flags=re.M)
        print(f"  pcscf/pcscf.cfg: {label} disabled")
    else:
        print(f"  pcscf/pcscf.cfg: WARN {label} line not found")
p.write_text(t)
PY

echo "== 3. PCF: qos_profiles + per-subscriber policy for the IMS session =="
python3 - <<'PY'
from pathlib import Path
p = Path("pcf/pcf.yaml")
t = p.read_text()
if "qos_profiles" in t:
    print("  pcf/pcf.yaml: already applied")
else:
    anchor = "    metrics:\n      server:\n        - address: PCF_IP\n          port: 9091"
    add = anchor + '''
    # The P-CSCF requests N5 QoS authorization with qosReference "qosVoNR"
    # (same reference for signalling and media in its route scripts); the PCF
    # resolves it through this table (unknown references are answered 403).
    qos_profiles:
      - reference: "qosVoNR"
        qos_index: 5
    # Config-based session data for the two test subscribers: internet (5QI 9)
    # and ims (5QI 5) + a PCC rule for the IMS signalling flow. Without a PCC
    # rule for the requested QoS index the PCF answers the P-CSCF with 403.
    policy:
      - supi_range:
          - 001010000000001-001010000000002
        plmn_id:
          mcc: 001
          mnc: 01
        slice:
          - sst: 1
            default_indicator: true
            session:
              - name: internet
                type: 1
                ambr:
                  downlink:
                    value: 1
                    unit: 3
                  uplink:
                    value: 1
                    unit: 3
                qos:
                  index: 9
                  arp:
                    priority_level: 8
                    pre_emption_vulnerability: 1
                    pre_emption_capability: 1
              - name: ims
                type: 1
                ambr:
                  downlink:
                    value: 1
                    unit: 3
                  uplink:
                    value: 1
                    unit: 3
                qos:
                  index: 5
                  arp:
                    priority_level: 1
                    pre_emption_vulnerability: 1
                    pre_emption_capability: 1
                pcc_rule:
                  - qos:
                      index: 5
                      arp:
                        priority_level: 1
                        pre_emption_vulnerability: 1
                        pre_emption_capability: 1
                      mbr:
                        downlink:
                          value: 3850
                          unit: 1
                        uplink:
                          value: 1530
                          unit: 1
                    flow:
                      - direction: 2
                        description: "permit out udp from any to assigned"
                      - direction: 1
                        description: "permit out udp from any to assigned"'''
    assert anchor in t, "metrics anchor not found in pcf/pcf.yaml"
    p.write_text(t.replace(anchor, add, 1))
    print("  pcf/pcf.yaml: qos_profiles + policy added")
PY

echo "== 4. pyHSS: route SIP MESSAGE to the SMSC on port 7090 =="
python3 - <<'PY'
from pathlib import Path

# The default iFC sends SIP MESSAGE to sip:smsc...:5060, but the SMSC listens on 7090.
# Without this, SMS never reaches the SMSC (the SMSC does not answer on 5060).
p = Path("pyhss/default_ifc.xml")
if not p.exists():
    print("  pyhss/default_ifc.xml: not found (skip)")
else:
    lines = p.read_text().splitlines(keepends=True)
    changed = 0
    for i, l in enumerate(lines):
        if "sip:smsc" in l and "org:5060</ServerName>" in l:
            lines[i] = l.replace("org:5060</ServerName>", "org:7090</ServerName>")
            changed += 1
    if changed:
        p.write_text("".join(lines))
        print(f"  pyhss/default_ifc.xml: smsc ServerName 5060 -> 7090 ({changed} line(s))")
    else:
        print("  pyhss/default_ifc.xml: already applied")
PY

echo "== done: rebuild/restart the affected containers =="
echo "   docker compose -f sa-vonr-deploy.yaml restart icscf pcscf pcf pyhss scscf"
