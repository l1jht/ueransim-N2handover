#!/bin/bash
# Provision two Open5GS + pyHSS subscribers for the VoNR N2-handover test.
#
#   - Open5GS HSS (open5gs-dbctl inside the webui container): APN internet + ims
#   - pyHSS (IMS, REST API via PUT + /list GETs): APN rows, AUC rows, subscriber rows,
#     IMS subscriber rows (S-CSCF pointer)
#
# Subscribers:
#   imsi-001010000000001 / msisdn 9076543210   (ue1)
#   imsi-001010000000002 / msisdn 9076543211   (ue2)
set -e

KI=8baf473f2f8fd09487cccbd7097c6862
OPC=8E27B6AF0E692E750F32667A3B14605D

echo "== Open5GS HSS provisioning (open5gs-dbctl) =="
for imsi in 001010000000001 001010000000002; do
    docker exec webui misc/db/open5gs-dbctl add_ue_with_apn "$imsi" "$KI" "$OPC" internet || true
    docker exec webui misc/db/open5gs-dbctl update_apn "$imsi" ims 0 || true
    echo "  provisioned $imsi (internet + ims)"
done

echo "== pyHSS (IMS) provisioning =="
python3 - "$KI" "$OPC" <<'PY'
import json
import sys
import time
import urllib.error
import urllib.request

KI, OPC = sys.argv[1], sys.argv[2]
BASE = "http://127.0.0.1:8080"
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
    print(f"  PUT {path} -> {st} {b[:120]}")
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

subs = [("001010000000001", "9076543210"), ("001010000000002", "9076543211")]
for imsi, msisdn in subs:
    auc_id = put_and_find("/auc/", {"ki": KI, "opc": OPC, "amf": "8000", "sqn": 0, "imsi": imsi},
                          "/auc/list", "auc_id", {"imsi": imsi})
    print("  auc:", imsi, auc_id)

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
    print("  ims subscriber:", imsi, msisdn)

print("pyHSS provisioning done")
PY
