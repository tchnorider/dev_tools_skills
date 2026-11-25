#!/usr/bin/env bash
# Run the skill's own checks. No Docker daemon required.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VALIDATOR="$ROOT/scripts/validate-container.sh"
RESOLVE="$ROOT/scripts/resolve-image-digest.sh"
GOOD="$ROOT/scripts/fixtures/good"
RUNTIME_GOOD="$ROOT/scripts/fixtures/runtime-good.json"
RUNTIME_BAD="$ROOT/scripts/fixtures/runtime-bad.json"
RUNTIME_STARTING="$ROOT/scripts/fixtures/runtime-starting.json"

if [[ ! -f "$ROOT/SKILL.md" ]]; then
  echo "SKILL.md is missing next to scripts/" >&2
  exit 1
fi

python3 - "$ROOT/SKILL.md" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
if not text.startswith("---\n"):
    raise SystemExit("SKILL.md is missing frontmatter")
frontmatter = text.split("---", 2)[1]
match = re.search(r"^description: '(.*)'\s*$", frontmatter, re.M)
if not match:
    raise SystemExit("description must be one single-quoted line")
description = match.group(1)
if "creates a new docker container named x" not in description:
    raise SystemExit("description is missing the trigger phrase")
if len(description) > 1024:
    raise SystemExit(f"description is {len(description)} characters")
if "name: create-docker-container" not in frontmatter:
    raise SystemExit("skill name does not match the folder")
PY

expect_rc() {
  local want="$1"
  shift
  local out rc
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  if [[ "$rc" -ne "$want" ]]; then
    printf '%s\n' "$out" >&2
    printf 'command exited %s, want %s: %s\n' "$rc" "$want" "$*" >&2
    exit 1
  fi
  printf '%s\n' "$out"
}

require_line() {
  local output="$1"
  local pattern="$2"
  if ! grep -q "$pattern" <<<"$output"; then
    printf '%s\n' "$output" >&2
    printf 'missing line: %s\n' "$pattern" >&2
    exit 1
  fi
}

reject_line() {
  local output="$1"
  local pattern="$2"
  if grep -q "$pattern" <<<"$output"; then
    printf '%s\n' "$output" >&2
    printf 'unexpected line: %s\n' "$pattern" >&2
    exit 1
  fi
}

expect_rc 2 bash "$RESOLVE" >/dev/null
expect_rc 2 bash "$RESOLVE" nginx:latest >/dev/null
expect_rc 2 bash "$RESOLVE" nginx:alpine >/dev/null
expect_rc 2 bash "$RESOLVE" nginx:stable >/dev/null
expect_rc 2 bash "$RESOLVE" nginx:1.2.3-rc.1 >/dev/null
expect_rc 2 bash "$RESOLVE" nginx:1.2.3-dev >/dev/null

static=$(expect_rc 0 bash "$VALIDATOR" --project "$GOOD" --static-only)
for id in \
  dockerfile-syntax from-digest from-tag-comment from-no-latest user-nonroot \
  no-add no-dist-upgrade no-ssh no-secret-env no-copy-secrets \
  multistage-when-compile minimal-runtime no-dev-tooling-final \
  healthcheck read-only no-new-privileges \
  cap-drop-all no-cap-add no-privileged no-host-namespaces no-docker-sock \
  no-sensitive-mounts no-shared-propagation no-unconfined memory-limit \
  cpu-limit pids-limit nofile-limit tmpfs-tmp user-defined-network egress \
  restart-on-failure log-rotation init container-name
do
  require_line "$static" "^PASS  ${id}  "
done
require_line "$static" "^SKIP  port-bind  "
reject_line "$static" "^FAIL  "

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/base"
cp -a "$GOOD/." "$work/base/"

mutate() {
  local name="$1"
  rm -rf "${work:?}/${name:?}"
  mkdir -p "$work/$name"
  cp -a "$work/base/." "$work/$name/"
}

mutate privileged
printf '\n    privileged: true\n' >> "$work/privileged/compose.yml"
privileged_out=$(expect_rc 1 bash "$VALIDATOR" --project "$work/privileged" --static-only)
require_line "$privileged_out" "^FAIL  no-privileged  "

mutate latest
sed -i 's|^FROM .*|FROM example.invalid/app:latest|' "$work/latest/Dockerfile"
latest_out=$(expect_rc 1 bash "$VALIDATOR" --project "$work/latest" --static-only)
require_line "$latest_out" "^FAIL  from-digest  "
require_line "$latest_out" "^FAIL  from-no-latest  "

mutate public
python3 - "$work/public/compose.yml" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
path.write_text(path.read_text().replace(
    "    networks:\n",
    "    ports:\n      - \"8080:8080\"\n    networks:\n",
    1,
))
PY
public_out=$(expect_rc 1 bash "$VALIDATOR" --project "$work/public" --static-only)
require_line "$public_out" "^FAIL  port-bind  "
public_ok=$(expect_rc 0 bash "$VALIDATOR" --project "$work/public" --static-only --allow-public-ports)
require_line "$public_ok" "^NOTE  port-bind  "

mutate localhost
python3 - "$work/localhost/compose.yml" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
path.write_text(path.read_text().replace(
    "    networks:\n",
    "    ports:\n      - \"127.0.0.1:8080:8080\"\n    networks:\n",
    1,
))
PY
localhost_out=$(expect_rc 0 bash "$VALIDATOR" --project "$work/localhost" --static-only)
require_line "$localhost_out" "^PASS  port-bind  "

mutate public_ip
python3 - "$work/public_ip/compose.yml" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
path.write_text(path.read_text().replace(
    "    networks:\n",
    "    ports:\n      - \"0.0.0.0:8080:8080\"\n    networks:\n",
    1,
))
PY
public_ip_out=$(expect_rc 1 bash "$VALIDATOR" --project "$work/public_ip" --static-only)
require_line "$public_ip_out" "^FAIL  port-bind  "
public_ip_ok=$(expect_rc 0 bash "$VALIDATOR" --project "$work/public_ip" --static-only --allow-public-ports)
require_line "$public_ip_ok" "^NOTE  port-bind  "

mutate low_port
python3 - "$work/low_port/compose.yml" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
path.write_text(path.read_text().replace(
    "    networks:\n",
    "    ports:\n      - \"0.0.0.0:80:8080\"\n    networks:\n",
    1,
))
PY
low_port_out=$(expect_rc 1 bash "$VALIDATOR" --project "$work/low_port" --static-only --allow-public-ports)
require_line "$low_port_out" "^FAIL  port-bind  "

mutate root
sed -i 's/user: "65532:65532"/user: root/' "$work/root/compose.yml"
sed -i 's/^USER .*/USER root/' "$work/root/Dockerfile"
root_out=$(expect_rc 1 bash "$VALIDATOR" --project "$work/root" --static-only)
require_line "$root_out" "^FAIL  user-nonroot  "
root_ok=$(expect_rc 0 bash "$VALIDATOR" --project "$work/root" --static-only --allow-root-entrypoint)
require_line "$root_ok" "^NOTE  user-nonroot  "

mutate internal
sed -i 's/driver: bridge/driver: bridge\n    internal: true/' "$work/internal/compose.yml"
internal_out=$(expect_rc 1 bash "$VALIDATOR" --project "$work/internal" --static-only)
require_line "$internal_out" "^FAIL  egress  "
internal_ok=$(expect_rc 0 bash "$VALIDATOR" --project "$work/internal" --static-only --internal-network)
require_line "$internal_ok" "^PASS  egress  "

mutate readonly
sed -i 's/read_only: true/read_only: false/' "$work/readonly/compose.yml"
readonly_out=$(expect_rc 1 bash "$VALIDATOR" --project "$work/readonly" --static-only)
require_line "$readonly_out" "^FAIL  read-only  "

mutate secrets
printf '\nENV API_KEY=supersecret\n' >> "$work/secrets/Dockerfile"
secrets_out=$(expect_rc 1 bash "$VALIDATOR" --project "$work/secrets" --static-only)
require_line "$secrets_out" "^FAIL  no-secret-env  "

mutate fatbase
{
  head -n 3 "$work/fatbase/Dockerfile"
  echo '# ubuntu:24.04'
  echo 'FROM ubuntu:24.04@sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08'
  tail -n +5 "$work/fatbase/Dockerfile"
} >"$work/fatbase/Dockerfile.new"
mv "$work/fatbase/Dockerfile.new" "$work/fatbase/Dockerfile"
fatbase_out=$(expect_rc 1 bash "$VALIDATOR" --project "$work/fatbase" --static-only)
require_line "$fatbase_out" "^FAIL  minimal-runtime  "

mutate onestage
printf '\nRUN npm ci && npm run build\n' >> "$work/onestage/Dockerfile"
onestage_out=$(expect_rc 1 bash "$VALIDATOR" --project "$work/onestage" --static-only)
require_line "$onestage_out" "^FAIL  multistage-when-compile  "

runtime_good=$(expect_rc 0 bash "$VALIDATOR" --project "$GOOD" --inspect-json "$RUNTIME_GOOD")
require_line "$runtime_good" "^PASS  runtime/read-only  "
require_line "$runtime_good" "^PASS  runtime/health  "
reject_line "$runtime_good" "^FAIL  "

runtime_bad=$(expect_rc 1 bash "$VALIDATOR" --project "$GOOD" --inspect-json "$RUNTIME_BAD")
for id in runtime/no-privileged runtime/no-docker-sock runtime/user-nonroot runtime/health runtime/running; do
  require_line "$runtime_bad" "^FAIL  ${id}  "
done

runtime_starting=$(expect_rc 2 bash "$VALIDATOR" --project "$GOOD" --inspect-json "$RUNTIME_STARTING")
require_line "$runtime_starting" "^WAIT  runtime/health  "
reject_line "$runtime_starting" "^FAIL  "

echo "validator checks passed"
