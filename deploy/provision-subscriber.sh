#!/bin/bash
# Provision the example subscriber used by config/ue.yaml on a free5GC WebUI.
#
#   usage: ./provision-subscriber.sh [webui-base-url]
#   default webui-base-url: http://127.0.0.1:5000
#
# The subscriber credentials match config/ue.yaml:
#   SUPI: imsi-208930000000001  K: 8baf...6862  OPc: 8e27...605d (OP type OPC)
set -euo pipefail

BASE="${1:-http://127.0.0.1:5000}"
PLMN="20893"

TOKEN=$(curl -s -X POST "$BASE/api/login" -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"free5gc"}' | jq -r '.access_token')
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "login failed (is the WebUI reachable at $BASE ?)" >&2
    exit 1
fi

read -r -d '' BODY <<'JSON' || true
{
  "plmnID": "20893",
  "ueId": "imsi-208930000000001",
  "AuthenticationSubscription": {
    "authenticationManagementField": "8000",
    "authenticationMethod": "5G_AKA",
    "opc": {"opcValue": "8e27b6af0e692e750f32667a3b14605d"},
    "permanentKey": {"permanentKeyValue": "8baf473f2f8fd09487cccbd7097c6862"},
    "sequenceNumber": "000000000023"
  },
  "AccessAndMobilitySubscriptionData": {
    "gpsis": ["msisdn-0900000000"],
    "subscribedUeAmbr": {"downlink": "2 Gbps", "uplink": "1 Gbps"},
    "nssai": {"defaultSingleNssais": [{"sst": 1, "sd": "010203", "isDefault": true}]}
  },
  "SessionManagementSubscriptionData": [
    {
      "singleNssai": {"sst": 1, "sd": "010203"},
      "dnnConfigurations": {
        "internet": {
          "pduSessionTypes": {"defaultSessionType": "IPV4", "allowedSessionTypes": ["IPV4"]},
          "sscModes": {"defaultSscMode": "SSC_MODE_1", "allowedSscModes": ["SSC_MODE_2", "SSC_MODE_3"]},
          "5gQosProfile": {"5qi": 9, "arp": {"priorityLevel": 8, "preemptCap": "", "preemptVuln": ""}, "priorityLevel": 8},
          "sessionAmbr": {"uplink": "1000 Mbps", "downlink": "1000 Mbps"},
          "staticIpAddress": []
        }
      }
    }
  ],
  "SmfSelectionSubscriptionData": {"subscribedSnssaiInfos": {"01010203": {"dnnInfos": [{"dnn": "internet"}]}}},
  "AmPolicyData": {"subscCats": ["free5gc"]},
  "SmPolicyData": {
    "smPolicySnssaiData": {
      "01010203": {
        "snssai": {"sst": 1, "sd": "010203"},
        "smPolicyDnnData": {"internet": {"dnn": "internet"}}
      }
    }
  },
  "FlowRules": [],
  "QosFlows": [],
  "ChargingDatas": []
}
JSON

if curl -s --fail -X POST "$BASE/api/subscriber/imsi-208930000000001/$PLMN" \
    -H "Content-Type: application/json" -H "Token: $TOKEN" -d "$BODY"; then
    echo "subscriber imsi-208930000000001 provisioned"
else
    echo "subscriber provisioning failed" >&2
    exit 1
fi
