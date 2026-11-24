"""Post a Tdarr transcode error to ntfy.

Tdarr flows have no error hook: a failed job only moves the file to the
"Transcode: Error/Cancelled" table in the UI. This loop asks the Tdarr API
every 15 minutes and posts each NEW failed file once to srv-urgent at
priority 3 (sound per the app's topic setting, no Do Not Disturb override).
A file that fails again after a retry posts again.

Standard library only, so the container needs no pip install.
"""

import json
import os
import time
import urllib.request

TDARR = os.environ.get("TDARR_URL", "http://tdarr:8266")
NTFY = os.environ.get("NTFY_URL", "http://ntfy/srv-urgent")
TOKEN_FILE = "/run/ntfy-token"
STATE = "/state/seen.json"
INTERVAL = int(os.environ.get("INTERVAL_SEC", "900"))


def log(*a):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), *a, flush=True)


def cruddb(collection: str) -> list:
    body = json.dumps({"data": {"collection": collection, "mode": "getAll"}}).encode()
    req = urllib.request.Request(TDARR + "/api/v2/cruddb", body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def errors() -> dict[str, str]:
    """{file path: error marker} for every file in the error table."""
    out = {}
    for f in cruddb("FileJSONDB"):
        if f.get("TranscodeDecisionMaker") == "Transcode error":
            out[f["_id"]] = str(f.get("lastTranscodeDate", ""))
        elif f.get("HealthCheck") == "Error":
            out[f["_id"]] = "health-" + str(f.get("lastHealthCheckDate", ""))
    return out


def notify(title: str, msg: str) -> None:
    with open(TOKEN_FILE) as fh:
        tok = fh.read().strip()
    req = urllib.request.Request(NTFY, msg.encode(), {
        "Authorization": "Bearer " + tok, "Title": title, "Priority": "3", "Tags": "warning,tdarr"})
    urllib.request.urlopen(req, timeout=15).close()


def main() -> None:
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    seen = json.load(open(STATE)) if os.path.exists(STATE) else None
    log("watching", TDARR, "every", INTERVAL, "s")
    while True:
        try:
            now = errors()
            if seen is None:
                # First start: remember existing errors, do not flood.
                seen = now
                log("baseline:", len(now), "file(s) in the error table")
            new = {p: m for p, m in now.items() if seen.get(p) != m}
            for p in new:
                log("new error:", p)
                notify("Tdarr: transcode failed", os.path.basename(p) +
                       "\nOpen tdarr.admin, Transcode: Error/Cancelled, for the job report.")
            seen = now
            with open(STATE, "w") as fh:
                json.dump(seen, fh)
        except Exception as e:  # noqa: BLE001  (Tdarr restarting, ntfy down)
            log("check failed:", e)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
