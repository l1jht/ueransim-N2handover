#!/bin/bash
# Provision the two test subscribers on the free5GC WebUI (5GC side) and on pyHSS
# (IMS side) for the free5GC + IMS testbed (Plan L).
#
#   usage: ./provision-free5gc-ims.sh [webui-base-url] [pyhss-base-url]
#   defaults: http://127.0.0.1:5000  http://127.0.0.1:8080
#
# WebUI payload includes, per subscriber:
#   - internet + ims DNNs (slice sst1/sd010203); the ims DNN default QoS is 5QI 5
#     (so the call runs on the default bearer; no N5/QoS signalling is used)
#   - SmfSelectionSubscriptionData + SmPolicyData with the ims DNN entry
#     (without the SmPolicyData entry the SMF/PCF SM policy create would fail)
# pyHSS payload (IMS HSS): APN rows, AUC/SUBSCRIBER/IMS_SUBSCRIBER (S-CSCF pointer).
set -euo pipefail

BASE="${1:-http://127.0.0.1:5000}"
PYHSS="${2:-http://127.0.0.1:8080}"
PLMN="00101"
KI=8baf473f2f8fd09487cccbd7097c6862
OPC=8E27B6AF0E692E750F32667A3B14605D

TOKEN=$(curl -s -X POST "$BASE/api/login" -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"free5gc"}' | jq -r '.access_token')
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "login failed (is the WebUI reachable at $BASE ?)" >&2
    exit 1
fi

provision_webui() { # imsi msisdn
    local IMSI=$1 MSISDN=$2 BODY
    read -r -d '' BODY <<JSON || true
{
  "plmnID": "$PLMN",
  "ueId": "imsi-$IMSI",
  "AuthenticationSubscription": {
    "authenticationManagementField": "8000",
    "authenticationMethod": "5G_AKA",
    "opc": {"opcValue": "8e27b6af0e692e750f32667a3b14605d"},
    "permanentKey": {"permanentKeyValue": "8baf473f2f8fd09487cccbd7097c6862"},
    "sequenceNumber": "000000000023"
  },
  "AccessAndMobilitySubscriptionData": {
    "gpsis": ["msisdn-$MSISDN"],
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
        },
        "ims": {
          "pduSessionTypes": {"defaultSessionType": "IPV4", "allowedSessionTypes": ["IPV4"]},
          "sscModes": {"defaultSscMode": "SSC_MODE_1", "allowedSscModes": ["SSC_MODE_2", "SSC_MODE_3"]},
          "5gQosProfile": {"5qi": 5, "arp": {"priorityLevel": 1, "preemptCap": "", "preemptVuln": ""}, "priorityLevel": 1},
          "sessionAmbr": {"uplink": "1000 Mbps", "downlink": "1000 Mbps"},
          "staticIpAddress": []
        }
      }
    }
  ],
  "SmfSelectionSubscriptionData": {"subscribedSnssaiInfos": {"01010203": {"dnnInfos": [{"dnn": "internet"}, {"dnn": "ims"}]}}},
  "AmPolicyData": {"subscCats": ["free5gc"]},
  "SmPolicyData": {
    "smPolicySnssaiData": {
      "01010203": {
        "snssai": {"sst": 1, "sd": "010203"},
        "smPolicyDnnData": {"internet": {"dnn": "internet"}, "ims": {"dnn": "ims"}}
      }
    }
  },
  "FlowRules": [],
  "QosFlows": [],
  "ChargingDatas": []
}
JSON
    if curl -s --fail -X POST "$BASE/api/subscriber/imsi-$IMSI/$PLMN" \
        -H "Content-Type: application/json" -H "Token: $TOKEN" -d "$BODY"; then
        echo "  subscriber imsi-$IMSI provisioned (internet + ims)"
    else
        echo "  subscriber $IMSI provisioning failed" >&2
        exit 1
    fi
}

echo "== free5GC WebUI provisioning =="
provision_webui 001010000000001 9076543210
provision_webui 001010000000002 9076543211

echo "== pyHSS (IMS) provisioning =="
python3 - "$KI" "$OPC" "$PYHSS" <<'PY'
import json
import sys
import time
import urllib.error
import urllib.request

KI, OPC, BASE = sys.argv[1], sys.argv[2], sys.argv[3].rstrip("/")
SCSCF_PEER = "scscf.ims.mnc001.mcc001.3gppnetwork.org"
SCSCF_URI = "sip:scscf.ims.mnc001.mcc001.3gppnetwork.org:6060"
REALM = "ims.mnc001.mcc001.3gppnetwork.org"


def req(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method)
    if data:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=20) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def wait_up():
    for _ in range(90):
        st, _ = req("GET", "/apn/list")
        if st == 200:
            return
        time.sleep(2)
    raise SystemExit("pyHSS API did not come up")


def find_id(list_path, id_key, match):
    st, b = req("GET", list_path)
    if st != 200:
        return None
    try:
        rows = json.loads(b)
    except json.JSONDecodeError:
        return None
    if isinstance(rows, dict):
        rows = rows.get("result", rows.get("results", []))
    for row in rows:
        if all(str(row.get(k)) == str(v) for k, v in match.items()):
            return row.get(id_key)
    return None


def put_and_find(path, body, list_path, id_key, match):
    st, b = req("PUT", path, body)
    print(f"  PUT {path} -> {st}")
    if st in (200, 201):
        try:
            obj = json.loads(b)
            if isinstance(obj, dict) and obj.get(id_key) is not None:
                return obj[id_key]
        except json.JSONDecodeError:
            pass
    rid = find_id(list_path, id_key, match)
    if rid is None:
        raise SystemExit(f"cannot resolve {id_key} for {path}")
    return rid


wait_up()

apn_ids = {}
for apn in ("internet", "ims"):
    apn_ids[apn] = put_and_find("/apn/", {"apn": apn, "apn_ambr_dl": 0, "apn_ambr_ul": 0},
                                "/apn/list", "apn_id", {"apn": apn})
print("  apn ids:", apn_ids)

for imsi, msisdn in (("001010000000001", "9076543210"), ("001010000000002", "9076543211")):
    auc_id = put_and_find("/auc/", {"ki": KI, "opc": OPC, "amf": "8000", "sqn": 0, "imsi": imsi},
                          "/auc/list", "auc_id", {"imsi": imsi})
    put_and_find("/subscriber/",
                 {"imsi": imsi, "enabled": True, "auc_id": auc_id,
                  "default_apn": apn_ids["internet"],
                  "apn_list": f"{apn_ids['internet']},{apn_ids['ims']}",
                  "msisdn": msisdn, "ue_ambr_dl": 0, "ue_ambr_ul": 0},
                 "/subscriber/list", "subscriber_id", {"imsi": imsi})
    put_and_find("/ims_subscriber/",
                 {"imsi": imsi, "msisdn": msisdn, "msisdn_list": f"[{msisdn}]",
                  "ifc_path": "default_ifc.xml", "scscf": SCSCF_URI,
                  "scscf_realm": REALM, "scscf_peer": SCSCF_PEER},
                 "/ims_subscriber/list", "ims_subscriber_id", {"imsi": imsi})
    print(f"  ims subscriber {imsi} / {msisdn}")

print("pyHSS provisioning done")
PY
