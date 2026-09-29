#!/bin/bash
# IMS call continuity across N2 handovers on a docker_open5gs VoNR testbed.
#
# Sequence:
#   1) start/verify gNB1, gNB2 and UE1 (UE1 alone on gNB1 so that its gNB-side
#      ue-id can be identified unambiguously), then start UE2
#   2) UE1 calls UE2 (UE2 auto-answers) and both calls become CONFIRMED
#   3) capture the RTP relayed by rtpengine (one sidecar container in
#      rtpengine's network namespace, so both UEs' streams are visible)
#   4) N2 handover of UE1 to gNB2, then back to gNB1
#   5) verify the call survived both handovers, report the RTP gaps measured
#      around each handover and the correlated ho-events JSONL records
#
# Environment (all optional):
#   COMPOSE_DIR     directory used for docker compose (default: current dir)
#   COMPOSE_FILES   compose "-f ..." arguments (default: "-f sa-vonr-deploy.yaml")
#   RUN_DIR         output directory for captures/results (default: current dir)
#   HO_EVENTS_DIR   host directory with the per-gNB ho-events (default:
#                   "$RUN_DIR/ho-events")
#   TCPDUMP_IMAGE   image with tcpdump used for the RTP capture sidecar
#                   (default: ueransim-build:22.04)
#   RTPENGINE       rtpengine container name (default: rtpengine)
#   GNB1_ID/GNB2_ID target gNB ids used by "nr-cli handover" (default: 1 / 2)
#   NO_HANGUP=1     keep the call up at the end
#
# Usage:
#   ./run-ims-test.sh --start      # start the UERANSIM containers via compose
#   ./run-ims-test.sh              # containers already running
set -u

RUN_DIR=${RUN_DIR:-$(pwd)}
COMPOSE_DIR=${COMPOSE_DIR:-$(pwd)}
COMPOSE_FILES=${COMPOSE_FILES:--f sa-vonr-deploy.yaml}
HO_EVENTS_DIR=${HO_EVENTS_DIR:-$RUN_DIR/ho-events}
TCPDUMP_IMAGE=${TCPDUMP_IMAGE:-ueransim-build:22.04}
RTPENGINE=${RTPENGINE:-rtpengine}
GNB1_ID=${GNB1_ID:-1}
GNB2_ID=${GNB2_ID:-2}

UE1=o5gs-ue1
UE2=o5gs-ue2
GNB1=o5gs-gnb1
GNB2=o5gs-gnb2
CLI=/ueransim/bin/nr-cli
IMSI1=imsi-001010000000001
IMSI2=imsi-001010000000002
CALL_URI=sip:001010000000002@ims.mnc001.mcc001.3gppnetwork.org

START=0
[ "${1:-}" = "--start" ] && START=1

RESULTS=$RUN_DIR/ims-ho-results
mkdir -p "$RESULTS"

gnb_name() { docker exec "$1" "$CLI" --dump 2>/dev/null | head -1; }
ims_status() { docker exec "$1" "$CLI" "$2" -e "ims-status" 2>&1; }
ims_field() { ims_status "$1" "$2" | sed -n "s/^[[:space:]]*$3: \"\\(.*\\)\".*/\\1/p"; }
ue_ids() { docker exec "$1" "$CLI" "$(gnb_name "$1")" -e "ue-list" 2>/dev/null | awk '/^- ue-id:/{print $3}'; }

wait_session() { # container
    for _ in $(seq 1 90); do
        docker exec "$1" ip -br addr 2>/dev/null | grep -q uesimtun && return 0
        sleep 2
    done
    return 1
}

wait_ims() { # container imsi
    for _ in $(seq 1 90); do
        ims_status "$1" "$2" | grep -q 'state: "REGISTERED"' && return 0
        sleep 2
    done
    return 1
}

wait_confirmed() { # container imsi
    for _ in $(seq 1 30); do
        ims_status "$1" "$2" | grep -q 'callState: "CONFIRMED"' && return 0
        sleep 1
    done
    return 1
}

compose_up() { # service...
    (cd "$COMPOSE_DIR" && docker compose $COMPOSE_FILES up -d "$@")
}

echo "== 1. bring up the testbed =="
if [ "$START" = 1 ]; then
    compose_up gnb1 gnb2 ue1 >/dev/null
fi
wait_session "$UE1" && echo "  ue1 PDU sessions up" || { echo "ue1 session FAILED"; exit 1; }
wait_ims "$UE1" "$IMSI1" && echo "  ue1 IMS registered" || { ims_status "$UE1" "$IMSI1"; exit 1; }

# UE1 is alone on gNB1 at this point -> its ue-id is unambiguous. If both UEs
# are already attached, fall back to the first id and warn.
IDS1=$(ue_ids "$GNB1")
if [ "$(echo "$IDS1" | grep -c .)" = 1 ]; then
    UE1_ID=$(echo "$IDS1" | head -1)
else
    UE1_ID=$(echo "$IDS1" | head -1)
    echo "  WARN: gNB1 already has several UEs; assuming UE1 has ue-id $UE1_ID"
fi
echo "  ue1 ue-id on gNB1: $UE1_ID"

if [ "$START" = 1 ]; then
    compose_up ue2 >/dev/null
fi
wait_session "$UE2" && echo "  ue2 PDU sessions up" || { echo "ue2 session FAILED"; exit 1; }
wait_ims "$UE2" "$IMSI2" && echo "  ue2 IMS registered" || { ims_status "$UE2" "$IMSI2"; exit 1; }

IP1=$(ims_field "$UE1" "$IMSI1" localIp)
IP2=$(ims_field "$UE2" "$IMSI2" localIp)
echo "  ue1 ims ip: $IP1 / ue2 ims ip: $IP2"

echo "== 2. ue1 calls ue2 =="
docker exec "$UE1" "$CLI" "$IMSI1" -e "ims-call $CALL_URI"
if wait_confirmed "$UE1" "$IMSI1" && wait_confirmed "$UE2" "$IMSI2"; then
    echo "  call CONFIRMED on both UEs"
else
    echo "  call did NOT reach CONFIRMED"; ims_status "$UE1" "$IMSI1"; ims_status "$UE2" "$IMSI2"; exit 1
fi

echo "== 3. RTP capture (rtpengine network namespace, both UEs) =="
docker run --rm --net="container:$RTPENGINE" -v "$RESULTS":/out "$TCPDUMP_IMAGE" \
    sh -c "timeout 75 tcpdump -n -tt -l -i any 'udp and (host $IP1 or host $IP2)'" \
    > "$RESULTS/rtp.txt" 2>&1 &
sleep 4
CAPTURED=$(grep -c 'IP ' "$RESULTS/rtp.txt" || true)
echo "  capture running ($CAPTURED packets in the first seconds)"
if [ "${CAPTURED:-0}" -lt 10 ]; then
    echo "  WARN: no (or very little) RTP seen; check TCPDUMP_IMAGE / RTPENGINE"
fi

echo "== 4. N2 handover ue1: gNB$GNB1_ID -> gNB$GNB2_ID, then back =="
echo "  $GNB1 ue-list: $(ue_ids "$GNB1" | tr '\n' ' ')"
echo "  $GNB2 ue-list: $(ue_ids "$GNB2" | tr '\n' ' ')"
docker exec "$GNB1" "$CLI" "$(gnb_name "$GNB1")" -e "handover $UE1_ID $GNB2_ID"
sleep 12
wait_confirmed "$UE1" "$IMSI1" && wait_confirmed "$UE2" "$IMSI2" \
    && echo "  call still CONFIRMED after handover 1" \
    || { echo "  call LOST after handover 1"; exit 1; }

IDS2=$(ue_ids "$GNB2")
UE1_ID2=$(echo "$IDS2" | head -1)
echo "  ue1 ue-id on gNB2: $UE1_ID2"
docker exec "$GNB2" "$CLI" "$(gnb_name "$GNB2")" -e "handover $UE1_ID2 $GNB1_ID"
sleep 12
wait_confirmed "$UE1" "$IMSI1" && wait_confirmed "$UE2" "$IMSI2" \
    && echo "  call still CONFIRMED after handover 2" \
    || { echo "  call LOST after handover 2"; exit 1; }

echo "== 5. media counters after the handovers =="
ims_status "$UE1" "$IMSI1" | tee "$RESULTS/after-ue1.txt" | grep -E "callState|media" | sed 's/^/  ue1 /'
ims_status "$UE2" "$IMSI2" | tee "$RESULTS/after-ue2.txt" | grep -E "callState|media" | sed 's/^/  ue2 /'

wait # let the capture finish
echo "== 6. RTP gap analysis (rtpengine side) =="
python3 - "$RESULTS/rtp.txt" "$IP1" "$IP2" <<'PY'
import re, sys
path, ip1, ip2 = sys.argv[1], sys.argv[2], sys.argv[3]
pat = re.compile(r"^(\d+\.\d+)\s+\S+\s+(In|Out)\s+IP\s+(\S+)\s+>\s+(\S+):\s+UDP,\s+length\s+(\d+)")
ev = []
for line in open(path, errors="replace"):
    m = pat.match(line)
    if m:
        ev.append((float(m.group(1)), m.group(3), m.group(4)))
def analyze(label, f):
    ts = sorted(t for t, sp, dp in ev if f(sp, dp))
    if len(ts) < 2:
        print(f"  {label}: no packets captured")
        return None
    gaps = [(b - a, a, b) for a, b in zip(ts, ts[1:])]
    g = max(gaps)
    big = [x for x in gaps if x[0] > 0.06]
    print(f"  {label}: packets={len(ts)} duration={ts[-1]-ts[0]:.2f}s "
          f"max_gap={g[0]*1000:.1f}ms gaps>60ms={len(big)}")
    for gg in sorted(big, reverse=True)[:3]:
        print(f"      gap {gg[0]*1000:.1f} ms at {gg[1]:.3f}")
analyze("ue1 downlink", lambda sp, dp: dp.startswith(ip1 + "."))
analyze("ue1 uplink  ", lambda sp, dp: sp.startswith(ip1 + "."))
analyze("ue2 downlink", lambda sp, dp: dp.startswith(ip2 + "."))
analyze("ue2 uplink  ", lambda sp, dp: sp.startswith(ip2 + "."))
PY

echo "== 7. ho-events correlation =="
python3 - "$HO_EVENTS_DIR" <<'PY'
import glob, json, os, sys, collections
root = sys.argv[1]
ho = collections.defaultdict(lambda: collections.defaultdict(list))
for f in glob.glob(os.path.join(root, "*", "*.ho-events.jsonl")):
    for line in open(f, errors="replace"):
        try:
            e = json.loads(line)
        except Exception:
            continue
        ho[e.get("ho_id")][e.get("node")].append(e.get("phase"))
if not ho:
    print(f"  no ho-events found under {root}")
for hid in sorted(ho, key=lambda h: h or 0)[-2:]:
    print(f"  ho_id {hid}:")
    for node, phases in sorted(ho[hid].items()):
        print(f"    {node}: {', '.join(phases)}")
PY

if [ "${NO_HANGUP:-0}" != 1 ]; then
    docker exec "$UE1" "$CLI" "$IMSI1" -e "ims-hangup" >/dev/null 2>&1
    echo "  call released (NO_HANGUP=1 to keep it)"
fi
echo "== done (artifacts in $RESULTS) =="
