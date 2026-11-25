#!/usr/bin/env bash
# Verify Docker Engine and bundled containerd meet minimum security patch levels.
# Exit 0: meets minimum. Exit 1: below minimum. Exit 2: Docker missing or daemon unreachable.
set -euo pipefail

MIN_ENGINE="${MIN_DOCKER_ENGINE_VERSION:-29.9.1}"
MIN_CONTAINERD="${MIN_CONTAINERD_VERSION:-2.4.2}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)

usage() {
  cat <<EOF
usage: check-docker-versions.sh [--json]

Requires a running Docker daemon. Compares Engine and containerd to:
  Engine >= ${MIN_ENGINE}
  containerd >= ${MIN_CONTAINERD}
EOF
}

json_out=0
if [[ "${1:-}" == "--json" ]]; then
  json_out=1
elif [[ -n "${1:-}" ]]; then
  usage >&2
  exit 2
fi

version_json=""
if [[ -n "${CHECK_DOCKER_VERSION_JSON_FILE:-}" ]]; then
  version_json=$(<"${CHECK_DOCKER_VERSION_JSON_FILE}")
elif [[ -n "${CHECK_DOCKER_VERSION_JSON:-}" ]]; then
  version_json="$CHECK_DOCKER_VERSION_JSON"
else
  if ! command -v docker >/dev/null 2>&1; then
    if [[ "$json_out" -eq 1 ]]; then
      printf '{"status":"error","reason":"docker_client_missing"}\n'
    else
      echo "ERROR  docker_client_missing  install Docker Engine before continuing" >&2
    fi
    exit 2
  fi
  if ! version_json=$(docker version -f '{{json .}}' 2>/dev/null); then
    if [[ "$json_out" -eq 1 ]]; then
      printf '{"status":"error","reason":"daemon_unreachable"}\n'
    else
      echo "ERROR  daemon_unreachable  start Docker or fix permissions" >&2
    fi
    exit 2
  fi
fi

result=$(CHECK_DOCKER_VERSION_JSON="$version_json" \
  MIN_ENGINE="$MIN_ENGINE" MIN_CONTAINERD="$MIN_CONTAINERD" python3 - <<'PY'
import json
import os
import re
import sys

MIN_ENGINE = os.environ["MIN_ENGINE"]
MIN_CONTAINERD = os.environ["MIN_CONTAINERD"]


def parse_version(raw: str):
    if not raw or raw in ("0", "unknown"):
        return None
    raw = raw.strip().lstrip("v")
    m = re.match(r"^(\d+(?:\.\d+)*)", raw)
    if not m:
        return None
    parts = [int(x) for x in m.group(1).split(".")]
    return parts


def cmp_versions(a: str | None, minimum: str):
    av = parse_version(a or "")
    bv = parse_version(minimum)
    if av is None:
        return None
    if bv is None:
        return True
    la, lb = len(av), len(bv)
    n = max(la, lb)
    av = av + [0] * (n - la)
    bv = bv + [0] * (n - lb)
    for x, y in zip(av, bv):
        if x < y:
            return False
        if x > y:
            return True
    return True


try:
    doc = json.loads(os.environ["CHECK_DOCKER_VERSION_JSON"])
except json.JSONDecodeError as e:
    print(json.dumps({"status": "error", "reason": "parse_failed", "detail": str(e)}))
    sys.exit(2)

server = doc.get("Server") or {}
engine = server.get("Version")
if not engine:
    engine = None

containerd = None
for comp in server.get("Components") or []:
    name = (comp.get("Name") or "").lower()
    if name == "containerd":
        containerd = comp.get("Version")
        break

if not containerd:
    # Legacy text-only layouts sometimes omit Components; try docker info when available.
    containerd = None

engine_ok = cmp_versions(engine, MIN_ENGINE)
ctr_ok = cmp_versions(containerd, MIN_CONTAINERD)

status = "ok"
if engine_ok is False or ctr_ok is False:
    status = "below_minimum"
elif engine_ok is None or ctr_ok is None:
    status = "unknown_component"

payload = {
    "status": status,
    "min_engine": MIN_ENGINE,
    "min_containerd": MIN_CONTAINERD,
    "engine_installed": engine,
    "containerd_installed": containerd,
    "engine_ok": engine_ok,
    "containerd_ok": ctr_ok,
}
print(json.dumps(payload))
PY
)

status=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["status"])' "$result")

if [[ "$json_out" -eq 1 ]]; then
  printf '%s\n' "$result"
else
  engine_inst=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("engine_installed") or "unknown")' "$result")
  ctr_inst=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("containerd_installed") or "unknown")' "$result")
  case "$status" in
    ok)
      echo "PASS  engine-version  Docker Engine ${engine_inst} >= ${MIN_ENGINE}"
      echo "PASS  containerd-version  containerd ${ctr_inst} >= ${MIN_CONTAINERD}"
      ;;
    below_minimum)
      engine_ok=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("engine_ok"))' "$result")
      ctr_ok=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("containerd_ok"))' "$result")
      echo "WARN  docker-versions  installed Engine ${engine_inst}, containerd ${ctr_inst}; require Engine >= ${MIN_ENGINE} and containerd >= ${MIN_CONTAINERD} because earlier releases have known security vulnerabilities"
      if [[ "$engine_ok" == "False" ]]; then
        echo "FAIL  engine-version  upgrade Docker Engine to ${MIN_ENGINE} or higher"
      else
        echo "PASS  engine-version  Docker Engine ${engine_inst} >= ${MIN_ENGINE}"
      fi
      if [[ "$ctr_ok" == "False" ]]; then
        echo "FAIL  containerd-version  upgrade bundled containerd to ${MIN_CONTAINERD} or higher (usually by upgrading Engine)"
      elif [[ "$ctr_ok" == "None" ]]; then
        echo "WARN  containerd-version  could not read bundled containerd version from docker version"
      else
        echo "PASS  containerd-version  containerd ${ctr_inst} >= ${MIN_CONTAINERD}"
      fi
      ;;
    unknown_component)
      echo "WARN  docker-versions  could not verify all component versions; treat the host as potentially out of date"
      ;;
    *)
      echo "ERROR  docker-versions  unexpected status ${status}" >&2
      ;;
  esac
fi

case "$status" in
  ok) exit 0 ;;
  below_minimum) exit 1 ;;
  *) exit 1 ;;
esac