#!/usr/bin/env bash
# Print a digest-pinned image reference for a specific stable tag.
# Stdout is one line: repository:tag@sha256:<digest>
# Diagnostics go to stderr. The script never falls back to :latest.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: resolve-image-digest.sh <repository>:<tag>
       resolve-image-digest.sh <repository>@sha256:<digest>

The tag must contain a version number. latest, stable, edge, and pre-release
tags are rejected. Stdout is the reference to put in FROM.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

die() {
  printf '%s\n' "$*" >&2
  exit 2
}

is_disallowed_tag() {
  local tag="$1"
  local lower
  lower=$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    latest|stable|edge|main|master|nightly|current|dev|test|testing)
      return 0
      ;;
  esac
  if [[ "$lower" =~ (^|[-_.])(rc|alpha|beta|dev|snapshot|preview|nightly|pre)([-.0-9]|$) ]]; then
    return 0
  fi
  if [[ ! "$lower" =~ [0-9] ]]; then
    return 0
  fi
  return 1
}

ref="$1"
digest=""
rest="$ref"

if [[ "$rest" == *@sha256:* ]]; then
  digest="${rest##*@}"
  rest="${rest%@*}"
  [[ "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || die "digest must be sha256 and 64 hex characters: $digest"
fi

tag=""
repo="$rest"
if [[ "$rest" == *:* ]]; then
  maybe="${rest##*:}"
  if [[ "$maybe" != */* ]]; then
    tag="$maybe"
    repo="${rest%:*}"
  fi
fi

[[ -n "$repo" && "$repo" != */ ]] || die "image repository is missing"
if [[ -z "$digest" && -z "$tag" ]]; then
  die "a specific version tag is required, for example nginx:1.27.4"
fi
if [[ -n "$tag" ]] && is_disallowed_tag "$tag"; then
  die "refusing floating or pre-release tag: $tag"
fi

if [[ -z "$digest" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    printf '%s\n' "docker is not installed" >&2
    exit 127
  fi
  lookup="$repo:$tag"
  if docker buildx version >/dev/null 2>&1; then
    digest=$(docker buildx imagetools inspect "$lookup" | awk -F': ' '/^Digest:/{print $2; exit}')
  fi
  if [[ -z "$digest" ]]; then
    printf '%s\n' "imagetools did not return a digest; pulling $lookup" >&2
    docker pull "$lookup" >&2
    repo_digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$lookup")
    digest="${repo_digest##*@}"
  fi
  [[ "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || die "could not resolve a digest for $lookup"
fi

if [[ -n "$tag" ]]; then
  printf '%s:%s@%s\n' "$repo" "$tag" "$digest"
else
  printf '%s@%s\n' "$repo" "$digest"
fi
