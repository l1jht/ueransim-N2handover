#!/bin/bash
# Drive N consecutive N2 handovers (optionally ping-pong between the two gNBs) and print,
# for every run, the last handover event emitted by the source gNB.
#
#   usage: ./ho-batch.sh [-n count] [-i interval_s] [-u ue_id] [-p]
#     -n  number of handovers (default 5)
#     -i  seconds to wait after each handover (default 3)
#     -u  UE id to use (default: auto-detect the first UE found on the current source gNB)
#     -p  ping-pong mode: alternate the target gNB between gnb1 and gnb2
#
# Environment (defaults match deploy/docker-compose.n2handover.yaml):
#   gnb1 = 10.100.200.101 / UERANSIM-gnb-208-93-1
#   gnb2 = 10.100.200.102 / UERANSIM-gnb-208-93-2
#
# Notes:
#   - The handover CLI is the stock `nr-cli` command implemented by the patch; no extra
#     tooling is required.
#   - A UE id is local to each gNB, so with `-u` in ping-pong mode you must pass an id that
#     exists on both gNBs or omit `-u` and let the script auto-detect per hop (single-UE case).
#   - Per-run measurements (phase timings) come from the JSONL event files written by the
#     gNBs (see docs/MEASUREMENT.md).
set -u

GNB1_CONTAINER=${GNB1_CONTAINER:-gnb1}; GNB1_NAME=${GNB1_NAME:-UERANSIM-gnb-208-93-1}
GNB2_CONTAINER=${GNB2_CONTAINER:-gnb2}; GNB2_NAME=${GNB2_NAME:-UERANSIM-gnb-208-93-2}
CLI=${CLI:-/ueransim/bin/nr-cli}

COUNT=5
INTERVAL=3
UE_ID=""
PINGPONG=0

while getopts "n:i:u:p" opt; do
    case "$opt" in
        n) COUNT=$OPTARG ;;
        i) INTERVAL=$OPTARG ;;
        u) UE_ID=$OPTARG ;;
        p) PINGPONG=1 ;;
        *) echo "usage: $0 [-n count] [-i interval] [-u ue-id] [-p]" >&2; exit 2 ;;
    esac
done

src_container=$GNB1_CONTAINER
src_name=$GNB1_NAME
dst_container=$GNB2_CONTAINER
dst_name=$GNB2_NAME

detect_ue() {
    docker exec "$1" "$CLI" "$2" -e "ue-list" | awk '/^- ue-id:/{print $3; exit}'
}

last_event() {
    docker exec "$1" sh -c "tail -n 1 /ueransim/logs/$2.ho-events.jsonl 2>/dev/null"
}

echo "== N2 handover batch: count=$COUNT interval=${INTERVAL}s pingpong=$PINGPONG =="
for i in $(seq 1 "$COUNT"); do
    id=${UE_ID:-$(detect_ue "$src_container" "$src_name")}
    if [ -z "${id:-}" ]; then
        echo "run[$i] no UE found on $src_container, stopping"
        exit 1
    fi

    target_gnb_id=${dst_name##*-}
    echo "run[$i] $src_container -> $dst_container (ue-id=$id, target-gnb-id=$target_gnb_id)"
    docker exec "$src_container" "$CLI" "$src_name" -e "handover $id $target_gnb_id" >/dev/null

    sleep "$INTERVAL"

    event=$(last_event "$src_container" "$src_name")
    if [ -n "$event" ]; then
        echo "        event: $event"
    else
        echo "        event: (no event file found; see gNB stdout log)"
    fi

    if [ "$PINGPONG" -eq 1 ]; then
        tmp=$src_container; src_container=$dst_container; dst_container=$tmp
        tmp=$src_name; src_name=$dst_name; dst_name=$tmp
    fi
done

echo "== done =="
