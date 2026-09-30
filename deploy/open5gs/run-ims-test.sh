#!/bin/bash
# IMS call continuity across N2 handovers (docker_open5gs / free5GC testbeds).
#
# v2: multi-round support and per-handover analysis.
#   -n <rounds>  number of round trips (each = 2 handovers), default 1
#   -w <secs>    wait after each handover, default 8
#   -u <id>      explicit ue1 gNB-side id on the first gNB (skips the probe)
#   --start      bring up gnb1/gnb2/ue1 (then ue2) via docker compose
#
# Sequence:
#   1) start/verify gNB1, gNB2 and UE1 (UE1 alone on GNB1 so its gNB-side ue-id
#      is unambiguous), then start UE2
#   2) UE1 calls UE2 (UE2 auto-answers) and both calls become CONFIRMED
#   3) capture the RTP relayed by rtpengine (a sidecar container in rtpengine's
#      network namespace sees both UEs' streams)
#   4) N2 handovers of UE1: out and back, -n times; the call must stay CONFIRMED
#   5) per-handover analysis: RTP gap window (from the ho-events wall clock),
#      control-plane phase durations (mono_ms), CSV + summary
#
# Environment (all optional):
#   COMPOSE_DIR     directory used for docker compose (default: current dir)
#   COMPOSE_FILES   compose "-f ..." arguments (default: "-f sa-vonr-deploy.yaml")
#   RUN_DIR         output directory (default: current dir)
#   HO_EVENTS_DIR   host directory with the per-gNB ho-events (default: $RUN_DIR/ho-events)
#   TCPDUMP_IMAGE   image with tcpdump for the capture sidecar (default: ueransim-build:22.04)
#   RTPENGINE       rtpengine container name (default: rtpengine)
#   GNB1_ID/GNB2_ID target gNB ids used by "nr-cli handover" (default: 1 / 2)
#   UE1/UE2/GNB1/GNB2  container names (defaults: o5gs-ue1 / o5gs-ue2 / o5gs-gnb1 / o5gs-gnb2)
#   MEDIA_PORT1/2   UE RTP ports used to capture/classify media (default: 50002 / 50003)
#   GAP_THRESHOLD_MS  gap threshold for "interruption" counting (default: 60)
#   NO_HANGUP=1     keep the call up at the end
set -u

RUN_DIR=${RUN_DIR:-$(pwd)}
COMPOSE_DIR=${COMPOSE_DIR:-$(pwd)}
COMPOSE_FILES=${COMPOSE_FILES:--f sa-vonr-deploy.yaml}
HO_EVENTS_DIR=${HO_EVENTS_DIR:-$RUN_DIR/ho-events}
TCPDUMP_IMAGE=${TCPDUMP_IMAGE:-ueransim-build:22.04}
RTPENGINE=${RTPENGINE:-rtpengine}
GNB1_ID=${GNB1_ID:-1}
GNB2_ID=${GNB2_ID:-2}
MEDIA_PORT1=${MEDIA_PORT1:-50002}
MEDIA_PORT2=${MEDIA_PORT2:-50003}
UE1=${UE1:-o5gs-ue1}
UE2=${UE2:-o5gs-ue2}
GNB1=${GNB1:-o5gs-gnb1}
GNB2=${GNB2:-o5gs-gnb2}
GAP_THRESHOLD_MS=${GAP_THRESHOLD_MS:-60}

ROUNDS=1
WAIT=8
START=0
UE1_ID_OPT=""
while [ $# -gt 0 ]; do
    case "$1" in
        -n) ROUNDS=$2; shift 2 ;;
        -w) WAIT=$2; shift 2 ;;
        -u) UE1_ID_OPT=$2; shift 2 ;;
        --start) START=1; shift ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
done

CLI=/ueransim/bin/nr-cli
IMSI1=imsi-001010000000001
IMSI2=imsi-001010000000002
CALL_URI=sip:001010000000002@ims.mnc001.mcc001.3gppnetwork.org

RESULTS=$RUN_DIR/ims-ho-results
mkdir -p "$RESULTS"

gnb_name() { docker exec "$1" "$CLI" --dump 2>/dev/null | head -1; }
ims_status() { docker exec "$1" "$CLI" "$2" -e "ims-status" 2>&1; }
ims_field() { ims_status "$1" "$2" | sed -n "s/^[[:space:]]*$3: \"\\(.*\\)\".*/\\1/p"; }
ue_ids() { docker exec "$1" "$CLI" "$(gnb_name "$1")" -e "ue-list" 2>/dev/null | awk '/^- ue-id:/{print $3}'; }
ue_ids_sorted() { ue_ids "$1" | grep -v '^$' | sort -n -u; }

wait_session() {
    for _ in $(seq 1 90); do
        docker exec "$1" ip -br addr 2>/dev/null | grep -q uesimtun && return 0
        sleep 2
    done
    return 1
}
wait_ims() {
    for _ in $(seq 1 90); do
        ims_status "$1" "$2" | grep -q 'state: "REGISTERED"' && return 0
        sleep 2
    done
    return 1
}
wait_confirmed() {
    for _ in $(seq 1 30); do
        ims_status "$1" "$2" | grep -q 'callState: "CONFIRMED"' && return 0
        sleep 1
    done
    return 1
}
compose_up() { (cd "$COMPOSE_DIR" && docker compose $COMPOSE_FILES up -d "$@"); }

echo "== 1. bring up the testbed =="
if [ "$START" = 1 ]; then
    compose_up gnb1 gnb2 ue1 >/dev/null
fi
wait_session "$UE1" && echo "  ue1 PDU sessions up" || { echo "ue1 session FAILED"; exit 1; }
wait_ims "$UE1" "$IMSI1" && echo "  ue1 IMS registered" || { ims_status "$UE1" "$IMSI1"; exit 1; }

if [ -n "$UE1_ID_OPT" ]; then
    UE1_ID=$UE1_ID_OPT
    echo "  ue1 ue-id on GNB1 (given): $UE1_ID"
else
    IDS1=$(ue_ids_sorted "$GNB1")
    if [ "$(echo "$IDS1" | grep -c .)" = 1 ]; then
        UE1_ID=$(echo "$IDS1" | head -1)
    else
        UE1_ID=$(echo "$IDS1" | head -1)
        echo "  WARN: gNB1 already has several UEs; assuming UE1 has ue-id $UE1_ID (use -u to override)"
    fi
    echo "  ue1 ue-id on GNB1: $UE1_ID"
fi

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

TOTAL=$((ROUNDS * 2))
CAPTURE=$((TOTAL * (WAIT + 3) + 40))
echo "== 3. RTP capture (rtpengine network namespace, ${CAPTURE}s, both UEs) =="
docker run --rm --net="container:$RTPENGINE" -v "$RESULTS":/out "$TCPDUMP_IMAGE" \
    sh -c "timeout $CAPTURE tcpdump -n -tt -l -i any 'udp and (port $MEDIA_PORT1 or port $MEDIA_PORT2)'" \
    > "$RESULTS/rtp.txt" 2>&1 &
sleep 4
CAPTURED=$(grep -c 'IP ' "$RESULTS/rtp.txt" || true)
echo "  capture running ($CAPTURED packets in the first seconds)"
if [ "${CAPTURED:-0}" -lt 10 ]; then
    echo "  WARN: no (or very little) RTP seen; check TCPDUMP_IMAGE / RTPENGINE"
fi

echo "== 4. N2 handovers: ue1 x $TOTAL (G$GNB1_ID <-> G$GNB2_ID) =="
CUR_GNB=$GNB1
CUR_ID=$UE1_ID
: > "$RESULTS/handovers.txt"
for k in $(seq 1 "$TOTAL"); do
    if [ "$CUR_GNB" = "$GNB1" ]; then TGT=$GNB2; TGT_ID=$GNB2_ID; else TGT=$GNB1; TGT_ID=$GNB1_ID; fi
    BEFORE=$(ue_ids_sorted "$TGT")
    echo "  [$k/$TOTAL] $CUR_GNB handover ue-id=$CUR_ID -> gNB$TGT_ID"
    docker exec "$CUR_GNB" "$CLI" "$(gnb_name "$CUR_GNB")" -e "handover $CUR_ID $TGT_ID"
    sleep "$WAIT"
    if wait_confirmed "$UE1" "$IMSI1" && wait_confirmed "$UE2" "$IMSI2"; then
        ST="CONFIRMED"
    else
        ST="LOST"
    fi
    AFTER=$(ue_ids_sorted "$TGT")
    NEW_ID=$(comm -13 <(echo "$BEFORE") <(echo "$AFTER") | tr '\n' ' ' | sed 's/ *$//')
    echo "$CUR_GNB->$TGT ue-id=$CUR_ID new-id-on-target='$NEW_ID' call=$ST" >> "$RESULTS/handovers.txt"
    if [ "$ST" = "LOST" ]; then
        echo "  call LOST after handover $k"; ims_status "$UE1" "$IMSI1" | grep -E "callState|error"; break
    fi
    CUR_ID=$(echo "$NEW_ID" | awk '{print $NF}')
    CUR_GNB=$TGT
done

wait

echo "== 5. media counters after the handovers =="
ims_status "$UE1" "$IMSI1" | tee "$RESULTS/after-ue1.txt" | grep -E "callState|media" | sed 's/^/  ue1 /'
ims_status "$UE2" "$IMSI2" | tee "$RESULTS/after-ue2.txt" | grep -E "callState|media" | sed 's/^/  ue2 /'

echo "== 6. per-handover analysis (RTP gaps + control-plane timings) =="
python3 - "$RESULTS/rtp.txt" "$RESULTS/handovers.csv" "$RESULTS/summary.txt" \
    "$MEDIA_PORT1" "$MEDIA_PORT2" "$ROUNDS" "$HO_EVENTS_DIR" "$GAP_THRESHOLD_MS" <<'PY'
import collections, glob, json, os, re, sys

rtp_path, csv_path, summary_path, mp1, mp2, rounds, ho_dir, thresh_ms = sys.argv[1:]
rounds = int(rounds); thresh = float(thresh_ms) / 1000.0
mp1, mp2 = int(mp1), int(mp2)

# --- handovers (append-only JSONL: keep the last 2*rounds by source wall clock)
ho = collections.defaultdict(dict)
for f in glob.glob(os.path.join(ho_dir, "*", "*.ho-events.jsonl")):
    for line in open(f, errors="replace"):
        try:
            e = json.loads(line)
        except Exception:
            continue
        ho[e.get("ho_id")].setdefault(e.get("role"), {})[e.get("phase")] = e

def t_of(h, phase, role):
    ev = h.get(role, {}).get(phase)
    return ev.get("wall_ms") if ev else None

items = []
for hid, h in ho.items():
    ts = t_of(h, "HO_REQUIRED_SENT", "source") or t_of(h, "HO_REQUEST_RECEIVED", "target")
    if ts:
        items.append((ts, hid))
items.sort()
sel = items[-2 * rounds:] if len(items) >= 2 * rounds else items

# --- rtp packets
pat = re.compile(r"^(\d+\.\d+)\s+\S+\s+(In|Out)\s+IP\s+(\S+)\s+>\s+(\S+):\s+UDP")
pkts = []
for line in open(rtp_path, errors="replace"):
    m = pat.match(line)
    if m:
        pkts.append((float(m.group(1)), m.group(3), m.group(4)))

def series(mp):
    """Classify by the UE-side media port (the port is preserved through NAT, so
    this works with and without a masquerading UPF):
    UL = source port == media port, DL = destination port == media port."""
    ul = sorted(t for t, s, d in pkts if int(s.rsplit(".", 1)[1]) == mp)
    dl = sorted(t for t, s, d in pkts if int(d.rsplit(".", 1)[1]) == mp)
    return dl, ul

def gap_stats(ts, lo, hi):
    w = [t for t in ts if lo <= t <= hi]
    if len(w) < 2:
        return None, 0, len(w)
    gaps = [b - a for a, b in zip(w, w[1:])]
    return max(gaps), sum(1 for g in gaps if g > thresh), len(w)

dl1, ul1 = series(mp1)
dl2, ul2 = series(mp2)

rows = []
for ts_wall, hid in sel:
    h = ho[hid]
    src_ts = t_of(h, "RRC_RECFG_SENT", "source") or ts_wall
    tgt_ts = t_of(h, "HO_NOTIFY_SENT", "target") or (src_ts + 2000)
    lo, hi = (src_ts - 1000) / 1000.0, (tgt_ts + 3000) / 1000.0
    def d(a, b):
        return (b - a) if (a is not None and b is not None and b >= a) else ""
    prep = d(t_of(h, "HO_REQUIRED_SENT", "source"), t_of(h, "HO_REQUEST_RECEIVED", "target"))
    ran = d(t_of(h, "RRC_RECFG_SENT", "source"), t_of(h, "RRC_RECFG_COMPLETE_RECEIVED", "target"))
    exec_ = d(t_of(h, "HO_COMMAND_RECEIVED", "source"), t_of(h, "HO_NOTIFY_SENT", "target"))
    rel = d(t_of(h, "HO_NOTIFY_SENT", "target"), t_of(h, "UE_CTX_RELEASE_RECEIVED", "source"))
    g1d, g1dn, _ = gap_stats(dl1, lo, hi)
    g1u, g1un, _ = gap_stats(ul1, lo, hi)
    g2d, g2dn, _ = gap_stats(dl2, lo, hi)
    g2u, g2un, _ = gap_stats(ul2, lo, hi)
    f = lambda x: "" if x is None else f"{x*1000:.1f}"
    rows.append(dict(ho_id=hid, src_gnb=h.get("source", {}).get("HO_REQUIRED_SENT", {}).get("node")
                     or "?", prep=prep, ran=ran, exec_=exec_, rel=rel,
                     g1d=f(g1d), g1u=f(g1u), g1dn=g1dn, g1un=g1un,
                     g2d=f(g2d), g2u=f(g2u), g2dn=g2dn, g2un=g2un))

with open(csv_path, "w") as fh:
    fh.write("ho_id,direction,prep_ms,ran_ms,exec_ms,release_ms,"
             "ue1_dl_max_ms,ue1_ul_max_ms,ue1_dl_gtN,ue1_ul_gtN,"
             "ue2_dl_max_ms,ue2_ul_max_ms,ue2_dl_gtN,ue2_ul_gtN\n")
    for r in rows:
        fh.write(f'{r["ho_id"]},{r["src_gnb"]},{r["prep"]},{r["ran"]},{r["exec_"]},{r["rel"]},'
                 f'{r["g1d"]},{r["g1u"]},{r["g1dn"]},{r["g1un"]},{r["g2d"]},{r["g2u"]},{r["g2dn"]},{r["g2un"]}\n')

def stats(name, key, gtkey):
    vals = sorted(float(r[key]) for r in rows if r[key] != "")
    if not vals:
        return f"  {name}: n/a"
    def pct(p):
        return vals[min(len(vals) - 1, int(len(vals) * p + 0.999) - 1)]
    gt = sum(int(r[gtkey]) for r in rows if r[key] != "")
    return (f"  {name}: n={len(vals)} min={vals[0]:.1f} med={pct(0.5):.1f} "
            f"p90={pct(0.9):.1f} max={vals[-1]:.1f} gaps>{thresh*1000:.0f}ms={gt}")

lines = []
lines.append(f"handovers analysed: {len(rows)} (threshold {thresh*1000:.0f} ms)")
lines.append("RTP gaps (ms), ue1 = handed-over UE, ue2 = control:")
for nm, k, gk in (("ue1 DL", "g1d", "g1dn"), ("ue1 UL", "g1u", "g1un"),
                  ("ue2 DL", "g2d", "g2dn"), ("ue2 UL", "g2u", "g2un")):
    lines.append(stats(nm, k, gk))
lines.append("control-plane phase durations (ms per handover):")
for key, label in (("prep", "prep(req->reqrecv)"), ("ran", "ran(recfg->recfgcmpl)"),
                   ("exec_", "exec(cmd->notify)"), ("rel", "release(notify->ctxrel)")):
    vals = [r[key] for r in rows if r[key] != ""]
    if vals:
        lines.append(f"  {label}: " + " ".join(f"{v:.0f}" for v in vals))
summary = "\n".join(lines) + "\n"
open(summary_path, "w").write(summary)
print(summary)
PY

if [ "${NO_HANGUP:-0}" != 1 ]; then
    docker exec "$UE1" "$CLI" "$IMSI1" -e "ims-hangup" >/dev/null 2>&1
    echo "  call released (NO_HANGUP=1 to keep it)"
fi
echo "== done (artifacts in $RESULTS) =="
