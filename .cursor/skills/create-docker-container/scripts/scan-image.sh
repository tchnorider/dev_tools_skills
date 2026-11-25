#!/usr/bin/env bash
# Scan a built image for critical and high vulnerabilities.
# Exit 0 when no scanner is installed, or when no critical/high issues are reported.
# Exit 1 when a scanner is installed and reports critical or high findings.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scan-image.sh <image-ref>

Tries Trivy, then Grype, then Docker Scout. Prints a short summary to stdout.
EOF
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

image="$1"

if command -v trivy >/dev/null 2>&1; then
  if trivy image --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1 "$image"; then
    printf 'SCANNER=trivy STATUS=pass IMAGE=%s\n' "$image"
    exit 0
  fi
  printf 'SCANNER=trivy STATUS=fail IMAGE=%s\n' "$image"
  trivy image --severity CRITICAL,HIGH --ignore-unfixed "$image" || true
  exit 1
fi

if command -v grype >/dev/null 2>&1; then
  if grype "$image" --fail-on high; then
    printf 'SCANNER=grype STATUS=pass IMAGE=%s\n' "$image"
    exit 0
  fi
  printf 'SCANNER=grype STATUS=fail IMAGE=%s\n' "$image"
  grype "$image" -o table | head -40 || true
  exit 1
fi

if docker scout version >/dev/null 2>&1; then
  if docker scout cves "$image" --only-severity critical,high --exit-code 1; then
    printf 'SCANNER=docker-scout STATUS=pass IMAGE=%s\n' "$image"
    exit 0
  fi
  printf 'SCANNER=docker-scout STATUS=fail IMAGE=%s\n' "$image"
  docker scout cves "$image" --only-severity critical,high || true
  exit 1
fi

printf 'SCANNER=none STATUS=skipped IMAGE=%s\n' "$image"
printf 'Install Trivy, Grype, or Docker Scout to enforce CVE checks.\n'
exit 0