#!/bin/bash
# Trigger an N2 handover on the source gNB and print the result from both gNBs.
#
#   usage: ./run-handover.sh [ue-id] [target-gnb-id] [gnb-name]
#   defaults: ue-id=1, target-gnb-id=2, gnb-name=UERANSIM-gnb-208-93-1
#
# Assumes the container names from deploy/docker-compose.n2handover.yaml (gnb1/gnb2).
set -euo pipefail

UE_ID="${1:-1}"
TARGET_GNB_ID="${2:-2}"
GNB_NAME="${3:-UERANSIM-gnb-208-93-1}"

echo "==> UE list on gnb1 (source)"
docker exec gnb1 /ueransim/bin/nr-cli "$GNB_NAME" -e "ue-list" || true

echo "==> Triggering handover: UE[${UE_ID}] -> gNB[${TARGET_GNB_ID}]"
docker exec gnb1 /ueransim/bin/nr-cli "$GNB_NAME" -e "handover ${UE_ID} ${TARGET_GNB_ID}"

echo "==> Waiting a few seconds for the procedure to complete..."
sleep 5

echo "==> UE list on gnb1 (source, expect empty after release)"
docker exec gnb1 /ueransim/bin/nr-cli "$GNB_NAME" -e "ue-list" || true

echo "==> UE list on gnb2 (target, expect the UE context)"
docker exec gnb2 /ueransim/bin/nr-cli "UERANSIM-gnb-208-93-2" -e "ue-list" || true
