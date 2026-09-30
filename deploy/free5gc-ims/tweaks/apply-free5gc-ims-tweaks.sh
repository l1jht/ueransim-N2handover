#!/bin/bash
# Apply the free5GC + IMS tweaks (Plan L) to one checkout. Auto-detects which side:
#
#   ./apply-free5gc-ims-tweaks.sh <free5GC-compose-dir>
#       PLMN 208/93 -> 001/01 (config/*cfg.yaml + uerouting.yaml)
#       AMF/SMF/UPF: add the "ims" DNN (SMF also delivers the P-CSCF via ePCO)
#       docker-compose.yaml: give free5gc-upf the static address 10.100.200.8
#
#   ./apply-free5gc-ims-tweaks.sh <docker_open5gs-dir>
#       keep N5 disabled (pcscf_init.sh does not re-enable WITH_N5 under DEPLOY_MODE=5G;
#       RX stays disabled as well) -> the P-CSCF never talks to SCP/NRF/PCF
#       NOTE: run deploy/open5gs/tweaks/apply-open5gs-tweaks.sh on this checkout FIRST
#             (it applies the I-CSCF LIR bypass, IPSec off, SIP/TCP off).
set -e

DIR=${1:-.}
cd "$DIR"

if [ -f sa-vonr-deploy.yaml ]; then
    echo "== docker_open5gs checkout: keep N5 disabled =="
    python3 - <<'PY'
import re
from pathlib import Path

p = Path("pcscf/pcscf_init.sh")
t = p.read_text()
if "# N5 disabled for the UERANSIM IMS client" in t:
    print("  pcscf/pcscf_init.sh: already applied")
elif "##!define WITH_N5" in t:
    pat = re.compile(r"^([ \t]*)sed -i 's\|##!define WITH_N5\\b\|#!define WITH_N5\|g' (/etc/kamailio_pcscf/pcscf\.cfg)$", re.M)
    m = pat.search(t)
    if not m:
        raise SystemExit("  pcscf/pcscf_init.sh: WITH_N5 enable line not found - inspect manually")
    indent = m.group(1)
    repl = (f"{indent}# N5 disabled for the UERANSIM IMS client (no QoS authorization; avoids the\n"
            f"{indent}# free5GC PDU Session Resource Modify path which UERANSIM does not implement).\n"
            f"{indent}#{m.group(0)[len(indent):]}")
    p.write_text(pat.sub(lambda _: repl, t, count=1))
    print("  pcscf/pcscf_init.sh: N5 keep-disabled applied")
else:
    print("  pcscf/pcscf_init.sh: WARN WITH_N5 line not found (already non-5G?)")
PY
    exit 0
fi

if [ -f docker-compose.yaml ] && [ -d config ]; then
    echo "== free5GC compose checkout: PLMN 001/01 + ims DNN + UPF static ip =="
    python3 - <<'PY'
import re
from pathlib import Path

# 1. PLMN 208/93 -> 001/01
for p in sorted(list(Path("config").glob("*cfg.yaml")) + [Path("config/uerouting.yaml")]):
    if not p.exists():
        continue
    t = p.read_text()
    t2 = t.replace("mcc: 208", "mcc: 001").replace("mnc: 93", "mnc: 01")
    if t2 != t:
        p.write_text(t2)
        print(f"  {p}: PLMN -> 001/01")

def sub_once(path, old, new, label):
    p = Path(path)
    t = p.read_text()
    if new in t:
        print(f"  {path}: {label} already applied")
        return
    if old not in t:
        raise SystemExit(f"  {path}: anchor not found for {label}")
    p.write_text(t.replace(old, new, 1))
    print(f"  {path}: {label} applied")

# 2. AMF supportDnnList += ims
sub_once("config/amfcfg.yaml",
         "  supportDnnList:  # the DNN (Data Network Name) list supported by this AMF\n    - internet\n",
         "  supportDnnList:  # the DNN (Data Network Name) list supported by this AMF\n    - internet\n    - ims\n",
         "AMF supportDnnList += ims")

# 3a. SMF dnnInfos (sd010203) += ims with ePCO P-CSCF
sub_once("config/smfcfg.yaml",
         """          dns: # the IP address of DNS
            ipv4: 8.8.8.8
            ipv6: 2001:4860:4860::8888
    - sNssai: # S-NSSAI (Single Network Slice Selection Assistance Information)
        sst: 1 # Slice/Service Type (uinteger, range: 0~255)
        sd: 112233 # Slice Differentiator (3 bytes hex string, range: 000000~FFFFFF)
""",
         """          dns: # the IP address of DNS
            ipv4: 8.8.8.8
            ipv6: 2001:4860:4860::8888
        - dnn: ims # IMS Data Network Name (P-CSCF delivered via ePCO 0x000C)
          dns:
            ipv4: 8.8.8.8
            ipv6: 2001:4860:4860::8888
          pcscf:
            ipv4: 10.100.200.47
    - sNssai: # S-NSSAI (Single Network Slice Selection Assistance Information)
        sst: 1 # Slice/Service Type (uinteger, range: 0~255)
        sd: 112233 # Slice Differentiator (3 bytes hex string, range: 000000~FFFFFF)
""",
         "SMF dnnInfos += ims(+pcscf)")

# 3b. SMF dnnUpfInfoList (sd010203) += ims pool
sub_once("config/smfcfg.yaml",
         """                staticPools:
                  - cidr: 10.60.100.0/24
          - sNssai: # S-NSSAI (Single Network Slice Selection Assistance Information)
""",
         """                staticPools:
                  - cidr: 10.60.100.0/24
              - dnn: ims
                pools:
                  - cidr: 192.168.101.0/24
          - sNssai: # S-NSSAI (Single Network Slice Selection Assistance Information)
""",
         "SMF dnnUpfInfoList += ims pool")

# 3c. SMF UPF interfaces networkInstances += ims
sub_once("config/smfcfg.yaml",
         """            networkInstances: # Data Network Name (DNN)
              - internet
""",
         """            networkInstances: # Data Network Name (DNN)
              - internet
              - ims
""",
         "SMF networkInstances += ims")

# 4. UPF dnnList += ims
sub_once("config/upfcfg.yaml",
         """  - dnn: internet # Data Network Name
    cidr: 10.61.0.0/16 # Classless Inter-Domain Routing for assigned IPv4 pool of UE
    # natifname: eth0
""",
         """  - dnn: internet # Data Network Name
    cidr: 10.61.0.0/16 # Classless Inter-Domain Routing for assigned IPv4 pool of UE
    # natifname: eth0
  - dnn: ims # IMS Data Network Name
    cidr: 192.168.101.0/24 # Classless Inter-Domain Routing for assigned IPv4 pool of UE
    # natifname: eth0
""",
         "UPF dnnList += ims")

# 5. free5gc-upf static address 10.100.200.8 (the IMS side routes UE pools via this IP)
p = Path("docker-compose.yaml")
t = p.read_text()
if "ipv4_address: 10.100.200.8" in t:
    print("  docker-compose.yaml: UPF static ip already applied")
else:
    lines = t.splitlines(keepends=True)
    out, done = [], False
    for i, l in enumerate(lines):
        out.append(l)
        if not done and l.strip() == "privnet:":
            if any("upf.free5gc.org" in lines[j] for j in range(i + 1, min(i + 4, len(lines)))):
                indent = " " * (len(l) - len(l.lstrip()) + 2)
                out.append(f"{indent}ipv4_address: 10.100.200.8\n")
                done = True
    if not done:
        raise SystemExit("  docker-compose.yaml: free5gc-upf networks block not found")
    p.write_text("".join(out))
    print("  docker-compose.yaml: UPF static ip 10.100.200.8 applied")
PY
    exit 0
fi

echo "error: $PWD does not look like a free5GC compose or docker_open5gs checkout"
exit 1
