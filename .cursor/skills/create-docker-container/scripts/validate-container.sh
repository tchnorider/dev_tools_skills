#!/usr/bin/env bash
# Check a container project against the create-docker-container baseline.
# Static checks read Dockerfile and compose.yml. Runtime checks read
# `docker inspect` after the container starts.
#
# Exit 0: every required check passed.
# Exit 1: one or more FAIL lines.
# Exit 2: usage error, or only WAIT (healthcheck still starting) and no FAIL.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: validate-container.sh --project DIR [--name NAME] [--static-only]
       [--allow-public-ports] [--allow-root-entrypoint] [--internal-network]
       [--inspect-json FILE]

--project is the containers/<name> directory.
--name defaults to compose container_name and must match it when set.
--static-only skips the running container.
--inspect-json reads a docker inspect JSON array instead of the daemon.
  Do not use it when creating a container. It is for the skill's own tests.
EOF
}

project=""
expected_name=""
static_only=0
allow_public=0
allow_root=0
internal_network=0
inspect_json=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      project="${2:-}"
      shift 2
      ;;
    --name)
      expected_name="${2:-}"
      shift 2
      ;;
    --static-only)
      static_only=1
      shift
      ;;
    --allow-public-ports)
      allow_public=1
      shift
      ;;
    --allow-root-entrypoint)
      allow_root=1
      shift
      ;;
    --internal-network)
      internal_network=1
      shift
      ;;
    --inspect-json)
      inspect_json="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$project" || ! -d "$project" ]]; then
  usage >&2
  exit 2
fi

failed=0
pass() { printf 'PASS  %s  %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %s  %s\n' "$1" "$2"; failed=1; }
skip() { printf 'SKIP  %s  %s\n' "$1" "$2"; }
note() { printf 'NOTE  %s  %s\n' "$1" "$2"; }

is_bad_user() {
  local u="$1"
  u="${u//\"/}"
  u="${u//\'/}"
  u="${u#"${u%%[![:space:]]*}"}"
  u="${u%"${u##*[![:space:]]}"}"
  case "$u" in
    ""|root|0|0:0|root:root|0:root|root:0) return 0 ;;
  esac
  return 1
}

compose=""
if [[ -f "$project/compose.yml" ]]; then
  compose="$project/compose.yml"
elif [[ -f "$project/compose.yaml" ]]; then
  compose="$project/compose.yaml"
else
  fail container-name "compose.yml is missing"
fi

dockerfile="$project/Dockerfile"
if [[ ! -f "$dockerfile" ]]; then
  fail dockerfile-syntax "Dockerfile is missing"
fi

stripped=""
if [[ -n "$compose" ]]; then
  stripped=$(mktemp)
  sed -E 's/(^|[[:space:]])#.*$/\1/; /^[[:space:]]*$/d' "$compose" > "$stripped"
fi
# Reached from the EXIT trap. Shellcheck does not treat that as a call.
# shellcheck disable=SC2317
cleanup() {
  if [[ -n "${stripped:-}" && -f "${stripped:-}" ]]; then
    rm -f "$stripped"
  fi
  if [[ -n "${runtime_tmp:-}" && -f "${runtime_tmp:-}" ]]; then
    rm -f "$runtime_tmp"
  fi
  return 0
}
trap cleanup EXIT

file_container_name=""
if [[ -n "$stripped" ]]; then
  file_container_name=$(sed -nE 's/^[[:space:]]*container_name:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/p' "$stripped" | head -1 || true)
fi

if [[ -z "$file_container_name" ]]; then
  fail container-name "set container_name to the requested name"
elif [[ -n "$expected_name" && "$file_container_name" != "$expected_name" ]]; then
  fail container-name "container_name is ${file_container_name}, expected ${expected_name}"
else
  pass container-name "container_name is ${file_container_name}"
fi

if [[ -f "$dockerfile" ]]; then
  if grep -Eq '^# syntax=docker/dockerfile:1[[:space:]]*$' "$dockerfile"; then
    pass dockerfile-syntax "Dockerfile frontend is docker/dockerfile:1"
  else
    fail dockerfile-syntax "add # syntax=docker/dockerfile:1 as the first line"
  fi

  from_ok=1
  tag_ok=1
  latest_ok=1
  from_seen=0
  mapfile -t docker_lines < "$dockerfile"
  for i in "${!docker_lines[@]}"; do
    line="${docker_lines[$i]}"
    [[ "$line" =~ ^[[:space:]]*FROM[[:space:]]+ ]] || continue
    from_seen=1
    ref="${line#FROM }"
    ref="${ref%% [Aa][Ss] *}"
    ref="${ref%"${ref##*[![:space:]]}"}"
    if [[ "$ref" == "scratch" ]]; then
      continue
    fi
    if [[ ! "$ref" =~ @sha256:[0-9a-fA-F]{64}$ ]]; then
      from_ok=0
    fi
    if [[ "$ref" == *":latest"* || "$ref" == *":latest@"* ]]; then
      latest_ok=0
    fi
    tag_part=""
    without_digest="${ref%%@*}"
    if [[ "$without_digest" == *:* ]]; then
      tag_part="${without_digest##*:}"
    fi
    if [[ -n "$tag_part" && "$tag_part" == "latest" ]]; then
      latest_ok=0
    fi
    prev=""
    j=$((i - 1))
    while [[ $j -ge 0 ]]; do
      candidate="${docker_lines[$j]}"
      if [[ -n "${candidate//[[:space:]]/}" ]]; then
        prev="$candidate"
        break
      fi
      j=$((j - 1))
    done
    if [[ ! "$prev" =~ ^[[:space:]]*#.*[0-9]+\.[0-9]+ ]]; then
      tag_ok=0
    fi
  done

  if [[ "$from_seen" -eq 1 && "$from_ok" -eq 1 ]]; then
    pass from-digest "every FROM is pinned by digest"
  else
    fail from-digest "pin every FROM except scratch with @sha256:<64 hex>"
  fi
  if [[ "$tag_ok" -eq 1 ]]; then
    pass from-tag-comment "each pinned FROM has a version comment above it"
  else
    fail from-tag-comment "put the human tag, with a dotted version, in the comment above FROM"
  fi
  if [[ "$latest_ok" -eq 1 ]] && ! grep -Eq '^[^#]*:latest([[:space:]]|$|@)' "$dockerfile"; then
    pass from-no-latest "Dockerfile does not use :latest"
  else
    fail from-no-latest "replace :latest with a version tag and a digest"
  fi

  last_user=$(grep -E '^USER[[:space:]]+' "$dockerfile" | tail -1 | sed -E 's/^USER[[:space:]]+//' || true)
  compose_user=""
  if [[ -n "$stripped" ]]; then
    compose_user=$(sed -nE 's/^[[:space:]]*user:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/p' "$stripped" | head -1 || true)
  fi
  user_bad=0
  [[ -n "$last_user" ]] || user_bad=1
  [[ -n "$compose_user" ]] || user_bad=1
  if [[ -n "$last_user" ]] && is_bad_user "$last_user"; then
    user_bad=1
  fi
  if [[ -n "$compose_user" ]] && is_bad_user "$compose_user"; then
    user_bad=1
  fi
  if [[ "$user_bad" -eq 0 ]]; then
    pass user-nonroot "Dockerfile USER and Compose user are non-root"
  elif [[ "$allow_root" -eq 1 ]]; then
    note user-nonroot "root entrypoint accepted by the user; other controls still apply"
  else
    fail user-nonroot "set a non-root USER and the same Compose user"
  fi

  if grep -Eq '^ADD[[:space:]]' "$dockerfile"; then
    fail no-add "use COPY instead of ADD"
  else
    pass no-add "Dockerfile uses COPY"
  fi
  if grep -Eq 'apt(-get)?[[:space:]]+upgrade|apk[[:space:]]+upgrade|dnf[[:space:]]+upgrade|yum[[:space:]]+upgrade|pacman[[:space:]]+-Syu' "$dockerfile"; then
    fail no-dist-upgrade "do not upgrade the whole distribution in the image"
  else
    pass no-dist-upgrade "no distribution upgrade in the Dockerfile"
  fi
  if grep -Eq 'openssh|sshd' "$dockerfile"; then
    fail no-ssh "do not install SSH in the image"
  else
    pass no-ssh "no SSH in the Dockerfile"
  fi
fi

if [[ -n "$stripped" ]]; then
  if grep -Eq ':latest([[:space:]]|$|")' "$stripped"; then
    fail from-no-latest "Compose still references :latest"
  fi

  has_docker_health=0
  has_compose_health=0
  if [[ -f "$dockerfile" ]] && grep -Eq '^HEALTHCHECK[[:space:]]' "$dockerfile"; then
    has_docker_health=1
  fi
  if grep -Eq '^[[:space:]]*healthcheck:[[:space:]]*$' "$stripped"; then
    has_compose_health=1
  fi
  noop=0
  if [[ -f "$dockerfile" ]] && grep -Eq '^HEALTHCHECK.*\b(exit[[:space:]]+0|true)\b' "$dockerfile"; then
    noop=1
  fi
  if grep -Eq 'test:[[:space:]]*\[[^]]*"(true|exit 0)"' "$stripped"; then
    noop=1
  fi
  if [[ "$has_docker_health" -eq 1 || "$has_compose_health" -eq 1 ]]; then
    if [[ "$noop" -eq 1 ]]; then
      fail healthcheck "healthcheck must observe the real process, not true or exit 0"
    else
      pass healthcheck "a healthcheck is defined"
    fi
  else
    fail healthcheck "add a HEALTHCHECK or a Compose healthcheck"
  fi

  if grep -Eq 'read_only:[[:space:]]*true' "$stripped" && ! grep -Eq 'read_only:[[:space:]]*false' "$stripped"; then
    pass read-only "root filesystem is read-only"
  else
    fail read-only "set read_only: true"
  fi

  if grep -Eq 'no-new-privileges:true' "$stripped" && ! grep -Eq 'no-new-privileges:false' "$stripped"; then
    pass no-new-privileges "no-new-privileges is set"
  else
    fail no-new-privileges "set security_opt no-new-privileges:true"
  fi

  if grep -Eq '^[[:space:]]*cap_drop:[[:space:]]*$' "$stripped" && grep -Eq '^[[:space:]]*-[[:space:]]*"?ALL"?[[:space:]]*$' "$stripped"; then
    pass cap-drop-all "all capabilities are dropped"
  else
    fail cap-drop-all "set cap_drop to ALL"
  fi

  if grep -Eq '^[[:space:]]*cap_add:[[:space:]]*$' "$stripped"; then
    fail no-cap-add "do not add capabilities; listen on port 1024 or higher"
  else
    pass no-cap-add "no capabilities are added"
  fi

  if grep -Eq 'privileged:[[:space:]]*true' "$stripped"; then
    fail no-privileged "remove privileged mode"
  else
    pass no-privileged "container is not privileged"
  fi

  if grep -Eq '^[[:space:]]*(network_mode|pid|ipc|uts|userns_mode):[[:space:]]*"?host"?[[:space:]]*$' "$stripped"; then
    fail no-host-namespaces "do not share host network, pid, ipc, uts, or user namespaces"
  else
    pass no-host-namespaces "host namespaces are not shared"
  fi

  if grep -Eq 'docker\.sock' "$stripped"; then
    fail no-docker-sock "do not mount the Docker socket"
  else
    pass no-docker-sock "Docker socket is not mounted"
  fi

  if grep -Eq '(^|[[:space:]"'\''-])/(etc|proc|sys|boot|dev|usr|lib|lib64|var/lib/docker):' "$stripped"; then
    fail no-sensitive-mounts "do not bind sensitive host directories"
  else
    pass no-sensitive-mounts "no sensitive host directory is mounted"
  fi

  if grep -Eq 'propagation:[[:space:]]*"?shared"?[[:space:]]*$' "$stripped"; then
    fail no-shared-propagation "do not use shared mount propagation"
  else
    pass no-shared-propagation "mount propagation is not shared"
  fi

  if grep -Eq 'unconfined|label:disable' "$stripped"; then
    fail no-unconfined "do not disable seccomp, AppArmor, or SELinux labels"
  else
    pass no-unconfined "default seccomp and MAC profiles stay on"
  fi

  mem=$(sed -nE 's/^[[:space:]]*mem_limit:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/p' "$stripped" | head -1 || true)
  if [[ -n "$mem" && ! "$mem" =~ ^0([.]0+)?[bBkKmMgG]?$ ]]; then
    pass memory-limit "memory limit is ${mem}"
  else
    fail memory-limit "set mem_limit above zero"
  fi

  cpu=$(sed -nE 's/^[[:space:]]*cpus:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/p' "$stripped" | head -1 || true)
  if [[ -n "$cpu" ]] && awk -v v="$cpu" 'BEGIN { exit !(v+0 > 0) }'; then
    pass cpu-limit "cpu limit is ${cpu}"
  else
    fail cpu-limit "set cpus above zero"
  fi

  pids=$(sed -nE 's/^[[:space:]]*pids_limit:[[:space:]]*"?([0-9]+)"?.*/\1/p' "$stripped" | head -1 || true)
  if [[ -n "$pids" && "$pids" -gt 0 ]]; then
    pass pids-limit "pid limit is ${pids}"
  else
    fail pids-limit "set pids_limit above zero"
  fi

  if grep -Eq '^[[:space:]]*nofile:[[:space:]]*$' "$stripped" \
    && grep -Eq '^[[:space:]]*soft:[[:space:]]*[1-9]' "$stripped" \
    && grep -Eq '^[[:space:]]*hard:[[:space:]]*[1-9]' "$stripped"; then
    pass nofile-limit "nofile soft and hard limits are set"
  else
    fail nofile-limit "set ulimits.nofile soft and hard above zero"
  fi

  if grep -Eq '/tmp:.*noexec.*nosuid.*nodev.*size=' "$stripped" || grep -Eq '/tmp:.*nosuid.*noexec.*nodev.*size=' "$stripped"; then
    pass tmpfs-tmp "/tmp is a bounded noexec tmpfs"
  else
    fail tmpfs-tmp "mount tmpfs /tmp with noexec,nosuid,nodev,size"
  fi

  if grep -Eq '^networks:[[:space:]]*$' "$stripped" \
    && grep -Eq '^[[:space:]]+networks:[[:space:]]*$' "$stripped" \
    && ! grep -Eq '^[[:space:]]*driver:[[:space:]]*"?host"?[[:space:]]*$' "$stripped"; then
    pass user-defined-network "a user-defined bridge network is set"
  else
    fail user-defined-network "declare a user-defined bridge network"
  fi

  if grep -Eq '^[[:space:]]*internal:[[:space:]]*true[[:space:]]*$' "$stripped"; then
    internal_set=1
  else
    internal_set=0
  fi
  if [[ "$internal_network" -eq 1 && "$internal_set" -eq 1 ]]; then
    pass egress "network is internal"
  elif [[ "$internal_network" -eq 1 ]]; then
    fail egress "set the network internal: true"
  elif [[ "$internal_set" -eq 1 ]]; then
    fail egress "internal: true blocks outbound access the user allowed"
  else
    pass egress "outbound access stays available"
  fi

  if grep -Eq 'restart:[[:space:]]*"?on-failure:[1-9][0-9]*"?[[:space:]]*$' "$stripped"; then
    pass restart-on-failure "restart policy is on-failure with a limit"
  else
    fail restart-on-failure "set restart to on-failure with a retry limit"
  fi

  if grep -Eq 'max-size:' "$stripped" && grep -Eq 'max-file:' "$stripped"; then
    pass log-rotation "logs have max-size and max-file"
  else
    fail log-rotation "set logging max-size and max-file"
  fi

  if grep -Eq '^[[:space:]]*init:[[:space:]]*true[[:space:]]*$' "$stripped"; then
    pass init "an init process is enabled"
  else
    fail init "set init: true"
  fi

  port_lines=$(grep -E '^[[:space:]]*-[[:space:]]*["'"'"']?([0-9]|\[)' "$stripped" || true)
  if ! grep -Eq '^[[:space:]]*ports:[[:space:]]*$' "$stripped"; then
    skip port-bind "no ports published"
  elif [[ -z "$port_lines" ]]; then
    fail port-bind "ports is set but has no mapping"
  else
    port_bad=0
    port_public=0
    while IFS= read -r pline; do
      [[ -n "$pline" ]] || continue
      mapping="${pline##*-}"
      mapping="${mapping//\"/}"
      mapping="${mapping//\'/}"
      mapping="${mapping#"${mapping%%[![:space:]]*}"}"
      mapping="${mapping%"${mapping##*[![:space:]]}"}"
      ip=""
      host_port=""
      container_port=""
      if [[ "$mapping" =~ ^\[([0-9A-Fa-f:]+)\]:([0-9]+):([0-9]+)$ ]]; then
        ip="${BASH_REMATCH[1]}"
        host_port="${BASH_REMATCH[2]}"
        container_port="${BASH_REMATCH[3]}"
      elif [[ "$mapping" =~ ^([0-9.]+):([0-9]+):([0-9]+)$ ]]; then
        ip="${BASH_REMATCH[1]}"
        host_port="${BASH_REMATCH[2]}"
        container_port="${BASH_REMATCH[3]}"
      elif [[ "$mapping" =~ ^([0-9]+):([0-9]+)$ ]]; then
        host_port="${BASH_REMATCH[1]}"
        container_port="${BASH_REMATCH[2]}"
      else
        port_bad=1
        continue
      fi
      if [[ "$host_port" -lt 1024 || "$container_port" -lt 1024 ]]; then
        port_bad=1
        continue
      fi
      if [[ "$ip" == "127.0.0.1" || "$ip" == "::1" ]]; then
        continue
      fi
      if [[ "$allow_public" -eq 1 && ( -z "$ip" || "$ip" == "0.0.0.0" || "$ip" == "::" ) ]]; then
        port_public=1
        continue
      fi
      port_bad=1
    done <<< "$port_lines"
    if [[ "$port_bad" -eq 1 ]]; then
      fail port-bind "publish 127.0.0.1:host:container with both ports at 1024 or higher"
    elif [[ "$port_public" -eq 1 ]]; then
      note port-bind "port is published on a public address at the user's request"
    else
      pass port-bind "published ports are bound to localhost"
    fi
  fi
fi

runtime_rc=0
if [[ "$static_only" -eq 0 ]]; then
  runtime_tmp=""
  runtime_file=""
  if [[ -n "$inspect_json" ]]; then
    runtime_file="$inspect_json"
  else
    if ! command -v docker >/dev/null 2>&1; then
      fail runtime/exists "docker is not installed"
    elif [[ -z "$file_container_name" ]]; then
      fail runtime/exists "container name is missing, so it was not inspected"
    else
      runtime_tmp=$(mktemp)
      if docker inspect "$file_container_name" > "$runtime_tmp" 2>/dev/null; then
        runtime_file="$runtime_tmp"
      else
        fail runtime/exists "container ${file_container_name} is not visible to docker"
      fi
    fi
  fi

  if [[ -n "$runtime_file" ]]; then
    set +e
    python3 - "$runtime_file" "$allow_public" "$allow_root" <<'PY'
import json
import sys

path, allow_public, allow_root = sys.argv[1:4]
allow_public = allow_public == "1"
allow_root = allow_root == "1"
code = 0

def emit(kind, check_id, message):
    global code
    print(f"{kind}  {check_id}  {message}")
    if kind == "FAIL":
        code = 1
    elif kind == "WAIT" and code == 0:
        code = 2

def as_list(value):
    return value if isinstance(value, list) else []

try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, json.JSONDecodeError) as exc:
    emit("FAIL", "runtime/exists", f"could not read inspect json: {exc}")
    sys.exit(1)

if not isinstance(data, list) or not data:
    emit("FAIL", "runtime/exists", "inspect json did not contain a container")
    sys.exit(1)

item = data[0]
cfg = item.get("Config") or {}
hc = item.get("HostConfig") or {}
state = item.get("State") or {}

user = str(cfg.get("User") or "")
bad_users = {"", "root", "0", "0:0", "root:root", "0:root", "root:0"}
if user in bad_users:
    if allow_root:
        emit("NOTE", "runtime/user-nonroot", "root entrypoint accepted by the user")
    else:
        emit("FAIL", "runtime/user-nonroot", f"container user is {user or 'root'}")
else:
    emit("PASS", "runtime/user-nonroot", f"container user is {user}")

if hc.get("ReadonlyRootfs") is True:
    emit("PASS", "runtime/read-only", "root filesystem is read-only")
else:
    emit("FAIL", "runtime/read-only", "ReadonlyRootfs is not true")

security = " ".join(as_list(hc.get("SecurityOpt")))
if "no-new-privileges" in security and "no-new-privileges:false" not in security:
    emit("PASS", "runtime/no-new-privileges", "no-new-privileges is set")
else:
    emit("FAIL", "runtime/no-new-privileges", "no-new-privileges is missing")
if "unconfined" in security or "label:disable" in security:
    emit("FAIL", "runtime/no-unconfined", "a security profile is unconfined")
else:
    emit("PASS", "runtime/no-unconfined", "default security profiles stay on")

dropped = {cap.upper() for cap in as_list(hc.get("CapDrop"))}
if "ALL" in dropped:
    emit("PASS", "runtime/cap-drop-all", "all capabilities are dropped")
else:
    emit("FAIL", "runtime/cap-drop-all", "CapDrop does not include ALL")

added = [cap.upper() for cap in as_list(hc.get("CapAdd"))]
if added:
    emit("FAIL", "runtime/no-cap-add", "capabilities were added: " + ",".join(added))
else:
    emit("PASS", "runtime/no-cap-add", "no capabilities are added")

if hc.get("Privileged") is True:
    emit("FAIL", "runtime/no-privileged", "container is privileged")
else:
    emit("PASS", "runtime/no-privileged", "container is not privileged")

namespaces = {
    "network": hc.get("NetworkMode") or "",
    "pid": hc.get("PidMode") or "",
    "ipc": hc.get("IpcMode") or "",
    "uts": hc.get("UTSMode") or "",
    "userns": hc.get("UsernsMode") or "",
}
hostish = [name for name, value in namespaces.items() if value == "host"]
if namespaces["network"] in {"bridge", "default"}:
    hostish.append("default-bridge")
if hostish:
    emit("FAIL", "runtime/no-host-namespaces", "unsafe namespace: " + ",".join(hostish))
else:
    emit("PASS", "runtime/no-host-namespaces", "host namespaces are not shared")

def norm(path):
    if not isinstance(path, str) or not path:
        return ""
    trimmed = path.rstrip("/")
    return trimmed or "/"

sensitive = {
    "/", "/etc", "/proc", "/sys", "/boot", "/dev", "/usr",
    "/lib", "/lib64", "/var/lib/docker",
    "/run/docker.sock", "/var/run/docker.sock",
}
sock = False
sensitive_hit = False
shared = False

def consider(source, dest="", propagation=""):
    global sock, sensitive_hit, shared
    source = source or ""
    dest = dest or ""
    if "docker.sock" in source or "docker.sock" in dest:
        sock = True
    if norm(source) in sensitive:
        sensitive_hit = True
    if str(propagation or "").lower() == "shared":
        shared = True

for bind in as_list(hc.get("Binds")):
    source = bind.split(":", 1)[0]
    consider(source, bind)

for mount in as_list(item.get("Mounts")):
    consider(mount.get("Source"), mount.get("Destination"), mount.get("Propagation"))

if sock:
    emit("FAIL", "runtime/no-docker-sock", "Docker socket is mounted")
else:
    emit("PASS", "runtime/no-docker-sock", "Docker socket is not mounted")
if sensitive_hit:
    emit("FAIL", "runtime/no-sensitive-mounts", "a sensitive host path is mounted")
else:
    emit("PASS", "runtime/no-sensitive-mounts", "no sensitive host path is mounted")
if shared:
    emit("FAIL", "runtime/no-shared-propagation", "a mount uses shared propagation")
else:
    emit("PASS", "runtime/no-shared-propagation", "mount propagation is not shared")

memory = hc.get("Memory") or 0
if isinstance(memory, int) and memory > 0:
    emit("PASS", "runtime/memory-limit", f"memory limit is {memory} bytes")
else:
    emit("FAIL", "runtime/memory-limit", "memory limit is unset")

nano = hc.get("NanoCpus") or 0
quota = hc.get("CpuQuota") or 0
if (isinstance(nano, int) and nano > 0) or (isinstance(quota, int) and quota > 0):
    emit("PASS", "runtime/cpu-limit", "cpu limit is set")
else:
    emit("FAIL", "runtime/cpu-limit", "cpu limit is unset")

pids = hc.get("PidsLimit")
if isinstance(pids, int) and pids > 0:
    emit("PASS", "runtime/pids-limit", f"pid limit is {pids}")
else:
    emit("FAIL", "runtime/pids-limit", "pid limit is unset")

nofile = None
for limit in as_list(hc.get("Ulimits")):
    if limit.get("Name") == "nofile":
        nofile = limit
if nofile and (nofile.get("Hard") or 0) > 0 and (nofile.get("Soft") or 0) > 0:
    emit("PASS", "runtime/nofile-limit", "nofile ulimit is set")
else:
    emit("FAIL", "runtime/nofile-limit", "nofile ulimit is missing")

if hc.get("Init") is True:
    emit("PASS", "runtime/init", "an init process is enabled")
else:
    emit("FAIL", "runtime/init", "init is not enabled")

policy = hc.get("RestartPolicy") or {}
if policy.get("Name") == "on-failure" and (policy.get("MaximumRetryCount") or 0) > 0:
    emit("PASS", "runtime/restart-on-failure", "restart policy is on-failure with a limit")
else:
    emit("FAIL", "runtime/restart-on-failure", "restart policy is not on-failure with a limit")

logs = (hc.get("LogConfig") or {}).get("Config") or {}
if logs.get("max-size") and logs.get("max-file"):
    emit("PASS", "runtime/log-rotation", "log rotation is set")
else:
    emit("FAIL", "runtime/log-rotation", "log rotation is missing")

bindings = hc.get("PortBindings") or {}
if not bindings:
    emit("SKIP", "runtime/port-bind", "no ports published")
else:
    port_bad = False
    port_public = False
    for container_port, hosts in bindings.items():
        try:
            container_number = int(str(container_port).split("/", 1)[0])
        except ValueError:
            container_number = 0
        if container_number < 1024:
            port_bad = True
        for host in hosts or []:
            ip = host.get("HostIp") or ""
            try:
                host_number = int(host.get("HostPort") or "0")
            except ValueError:
                host_number = 0
            if host_number < 1024:
                port_bad = True
            if ip in {"127.0.0.1", "::1"}:
                continue
            if allow_public and ip in {"", "0.0.0.0", "::"}:
                port_public = True
            else:
                port_bad = True
    if port_bad:
        emit("FAIL", "runtime/port-bind", "a published port is public or below 1024")
    elif port_public:
        emit("NOTE", "runtime/port-bind", "port is published on a public address at the user's request")
    else:
        emit("PASS", "runtime/port-bind", "published ports are bound to localhost")

devices = hc.get("Devices") or []
if devices:
    emit("FAIL", "runtime/no-devices", "a host device is passed through")
else:
    emit("PASS", "runtime/no-devices", "no host device is passed through")

status = state.get("Status") or ""
if status not in {"running", "restarting"}:
    emit("FAIL", "runtime/running", f"container status is {status or 'missing'}")
else:
    emit("PASS", "runtime/running", f"container status is {status}")

health = ((state.get("Health") or {}).get("Status") or "")
test = ((cfg.get("Healthcheck") or {}).get("Test") or [])
if not test or test == ["NONE"] or (test and test[0] == "NONE"):
    emit("FAIL", "runtime/health", "no healthcheck is configured")
elif health == "healthy":
    emit("PASS", "runtime/health", "healthcheck is healthy")
elif health == "starting":
    emit("WAIT", "runtime/health", "healthcheck is still starting")
elif status in {"running", "restarting"} and not health:
    emit("WAIT", "runtime/health", "healthcheck has not reported yet")
else:
    emit("FAIL", "runtime/health", f"health status is {health or 'missing'}")

sys.exit(code)
PY
    runtime_rc=$?
    set -e
  fi
fi

if [[ "$failed" -ne 0 || "$runtime_rc" -eq 1 ]]; then
  exit 1
fi
if [[ "$runtime_rc" -eq 2 ]]; then
  exit 2
fi
if [[ "$runtime_rc" -ne 0 ]]; then
  fail runtime/exists "runtime checker exited ${runtime_rc}"
  exit 1
fi
exit 0
