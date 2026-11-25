#!/usr/bin/env bash
# Post-creation verification: versions, compose, validator, image, scan.
# Prints a markdown result table to stdout. Exit 0 when no FAIL rows.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VALIDATOR="$ROOT/scripts/validate-container.sh"
VERSION_CHECK="$ROOT/scripts/check-docker-versions.sh"
SCAN="$ROOT/scripts/scan-image.sh"

usage() {
  cat <<'EOF'
usage: run-container-tests.sh --project DIR [--image REF] [--started]
       [--allow-public-ports] [--allow-root-entrypoint] [--internal-network]
       [--skip-host-versions]

Runs post-creation checks and prints a markdown table.
EOF
}

project=""
image_ref=""
started=0
skip_host=0
allow_public=0
allow_root=0
internal_network=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) project="${2:-}"; shift 2 ;;
    --image) image_ref="${2:-}"; shift 2 ;;
    --started) started=1; shift ;;
    --skip-host-versions) skip_host=1; shift ;;
    --allow-public-ports) allow_public=1; shift ;;
    --allow-root-entrypoint) allow_root=1; shift ;;
    --internal-network) internal_network=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [[ -z "$project" || ! -d "$project" ]]; then
  usage >&2
  exit 2
fi

compose="$project/compose.yml"
if [[ ! -f "$compose" ]]; then
  echo "compose.yml is missing under $project" >&2
  exit 2
fi

declare -a ROW_TEST=()
declare -a ROW_RESULT=()
declare -a ROW_IF_FAIL=()

record() {
  ROW_TEST+=("$1")
  ROW_RESULT+=("$2")
  ROW_IF_FAIL+=("$3")
}

val_args=(--project "$project")
[[ "$allow_public" -eq 1 ]] && val_args+=(--allow-public-ports)
[[ "$allow_root" -eq 1 ]] && val_args+=(--allow-root-entrypoint)
[[ "$internal_network" -eq 1 ]] && val_args+=(--internal-network)

overall_fail=0
note_result() {
  local r="$1"
  case "$r" in
    FAIL) overall_fail=1 ;;
  esac
}

# Host Docker versions
if [[ "$skip_host" -eq 1 ]]; then
  record "Host Docker versions (Engine ≥ 29.9.1, containerd ≥ 2.4.2)" "SKIP" \
    "Run check-docker-versions.sh on the host before production."
else
  set +e
  host_out=$(bash "$VERSION_CHECK" 2>&1)
  host_rc=$?
  set -e
  if [[ "$host_rc" -eq 0 ]]; then
    record "Host Docker versions (Engine ≥ 29.9.1, containerd ≥ 2.4.2)" "PASS" \
      "Upgrade with engine-upgrade.md, then re-run this test script."
  elif [[ "$host_rc" -eq 2 ]]; then
    record "Host Docker versions (Engine ≥ 29.9.1, containerd ≥ 2.4.2)" "SKIP" \
      "Start Docker or install Engine; then run check-docker-versions.sh."
  else
    record "Host Docker versions (Engine ≥ 29.9.1, containerd ≥ 2.4.2)" "FAIL" \
      "Upgrade with engine-upgrade.md, or confirm continuing without upgrade, then re-run."
  fi
  note_result "${ROW_RESULT[$((${#ROW_RESULT[@]} - 1))]}"
fi

# Compose config
if command -v docker >/dev/null 2>&1; then
  set +e
  docker compose -f "$compose" config -q 2>/dev/null
  cfg_rc=$?
  set -e
  if [[ "$cfg_rc" -eq 0 ]]; then
    record "Compose file syntax" "PASS" "Fix compose.yml until docker compose config succeeds."
  else
    record "Compose file syntax" "FAIL" "Fix YAML and fields in compose.yml; run docker compose -f $compose config."
    note_result "FAIL"
  fi
else
  record "Compose file syntax" "SKIP" "Install Docker; run docker compose config -f $compose."
fi

# Static hardening
set +e
static_out=$(bash "$VALIDATOR" "${val_args[@]}" --static-only 2>&1)
static_rc=$?
set -e
static_fails=$(grep -c '^FAIL  ' <<<"$static_out" || true)
if [[ "$static_rc" -eq 0 && "$static_fails" -eq 0 ]]; then
  record "Static hardening (Dockerfile + compose)" "PASS" \
    "Fix each FAIL id using references/security-baseline.md; re-run validate-container.sh --static-only."
else
  record "Static hardening (Dockerfile + compose)" "FAIL" \
    "Fix each FAIL id using references/security-baseline.md; re-run validate-container.sh --static-only."
  note_result "FAIL"
fi

# Local image
if [[ -n "$image_ref" ]]; then
  if command -v docker >/dev/null 2>&1; then
    set +e
    docker image inspect "$image_ref" >/dev/null 2>&1
    img_rc=$?
    set -e
    if [[ "$img_rc" -eq 0 ]]; then
      record "Local image present ($image_ref)" "PASS" \
        "Run docker compose build in $project; fix Dockerfile errors until the image exists."
    else
      record "Local image present ($image_ref)" "FAIL" \
        "Run docker compose build in $project; fix Dockerfile errors until the image exists."
      note_result "FAIL"
    fi
  else
    record "Local image present ($image_ref)" "SKIP" "Install Docker and build the image."
  fi
fi

# Runtime checks
if [[ "$started" -eq 1 ]]; then
  set +e
  live_out=$(bash "$VALIDATOR" "${val_args[@]}" 2>&1)
  live_rc=$?
  set -e
  live_fails=$(grep -c '^FAIL  ' <<<"$live_out" || true)
  live_waits=$(grep -c '^WAIT  ' <<<"$live_out" || true)

  if grep -q '^PASS  runtime/running' <<<"$live_out"; then
    record "Container running" "PASS" \
      "docker compose -f $compose up -d; read docker logs for the container name."
  elif [[ "$live_waits" -gt 0 && "$live_fails" -eq 0 ]]; then
    record "Container running" "WAIT" \
      "Wait for the healthcheck start period, then re-run run-container-tests.sh --started."
    overall_fail=1
  else
    record "Container running" "FAIL" \
      "docker compose -f $compose up -d; read docker logs for the container name."
    note_result "FAIL"
  fi

  if grep -q '^PASS  runtime/health' <<<"$live_out"; then
    record "Healthcheck healthy" "PASS" \
      "Fix HEALTHCHECK or the app; ensure the process exits non-zero when unhealthy."
  elif [[ "$live_waits" -gt 0 ]]; then
    record "Healthcheck healthy" "WAIT" \
      "Wait and re-run up to three times; fix the healthcheck or service if still WAIT."
    overall_fail=1
  else
    record "Healthcheck healthy" "FAIL" \
      "Fix HEALTHCHECK or the app; ensure the process exits non-zero when unhealthy."
    note_result "FAIL"
  fi

  if [[ "$live_rc" -eq 0 && "$live_fails" -eq 0 ]]; then
    record "Runtime hardening (live inspect)" "PASS" \
      "Recreate with docker compose up -d --force-recreate; align compose.yml with the baseline."
  elif [[ "$live_waits" -gt 0 && "$live_fails" -eq 0 ]]; then
    record "Runtime hardening (live inspect)" "WAIT" \
      "Re-run after healthcheck is healthy; fix any FAIL ids in security-baseline.md."
    overall_fail=1
  else
    record "Runtime hardening (live inspect)" "FAIL" \
      "Recreate with docker compose up -d --force-recreate; fix each FAIL id in security-baseline.md."
    note_result "FAIL"
  fi
elif [[ "$started" -eq 0 ]]; then
  record "Container running" "SKIP" "Pass --started after docker compose up -d."
  record "Healthcheck healthy" "SKIP" "Pass --started after docker compose up -d."
  record "Runtime hardening (live inspect)" "SKIP" "Pass --started after docker compose up -d."
fi

# Vulnerability scan
if [[ -n "$image_ref" ]]; then
  if command -v docker >/dev/null 2>&1; then
    set +e
    scan_out=$(bash "$SCAN" "$image_ref" 2>&1)
    scan_rc=$?
    set -e
    if grep -q 'SCANNER=none' <<<"$scan_out"; then
      record "Vulnerability scan (critical/high)" "WARN" \
        "Install Trivy, Grype, or Docker Scout; re-run scan-image.sh on $image_ref."
    elif [[ "$scan_rc" -eq 0 ]]; then
      record "Vulnerability scan (critical/high)" "PASS" \
        "Update base or packages; rebuild; do not downgrade the digest to hide CVEs."
    else
      record "Vulnerability scan (critical/high)" "FAIL" \
        "Update base or packages; rebuild; do not downgrade the digest to hide CVEs."
      note_result "FAIL"
    fi
  else
    record "Vulnerability scan (critical/high)" "SKIP" "Install Docker and a scanner; run scan-image.sh."
  fi
fi

escape_md() {
  sed 's/|/\\|/g' <<<"$1"
}

printf '## Verification results\n\n'
printf '| Test | Result | If this fails |\n'
printf '| --- | --- | --- |\n'
for i in "${!ROW_TEST[@]}"; do
  t=$(escape_md "${ROW_TEST[$i]}")
  r="${ROW_RESULT[$i]}"
  f=$(escape_md "${ROW_IF_FAIL[$i]}")
  printf '| %s | %s | %s |\n' "$t" "$r" "$f"
done
printf '\n'

if [[ "$overall_fail" -eq 0 ]]; then
  printf '_Overall: all required checks passed or were skipped with a documented reason._\n'
  exit 0
fi

printf '_Overall: one or more checks failed or are still WAIT. Fix the rows marked FAIL or WAIT, then re-run this script._\n'
exit 1