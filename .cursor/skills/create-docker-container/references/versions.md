# Versions to target

This file was checked on 21 November 2026. Treat it as stale until you look the versions up again during the creation interview.

| Item | Snapshot on 21 November 2026 | Look up before creating |
| --- | --- | --- |
| **Minimum Docker Engine (security floor)** | **29.9.1** | Enforced by `scripts/check-docker-versions.sh` |
| **Minimum bundled containerd (security floor)** | **2.4.2** | Same script; upgrade via Engine when bundled |
| Docker Engine stable | 29.10.0, released 16 November 2026 | https://docs.docker.com/engine/release-notes/ and https://github.com/moby/moby/releases |
| Engine API for 29.10 | 1.57 | https://docs.docker.com/reference/api/engine/ |
| CIS Docker Benchmark | 1.9.0, for Docker 29.x, in the November 2026 CIS update | https://www.cisecurity.org/benchmark/docker |
| Dockerfile frontend | `# syntax=docker/dockerfile:1` | https://docs.docker.com/build/building/best-practices/ |

If the lookup shows a newer Engine or benchmark, use the newer one and record it in the FAQ. Do not quietly keep these snapshot numbers.

## How to use the lookup

- Run `bash scripts/check-docker-versions.sh` before the interview. Engine must be **≥ 29.9.1** and bundled containerd **≥ 2.4.2** because earlier versions have known security vulnerabilities. When the check fails, warn the user and ask whether to upgrade, continue without upgrading, or stop. See [engine-upgrade.md](engine-upgrade.md).
- Record the installed client and server versions from `docker version`, bundled containerd from the same output, and the Compose version from `docker compose version`.
- The container project has to be valid on the installed Engine. When Engine meets the security floor but is older than the current stable release, note it in the FAQ without blocking unless the user cares.
- Do not set `DOCKER_CONTENT_TRUST`. Docker retired Content Trust. Pin every `FROM` by digest, and verify a signature or attestation when the publisher provides one and the tools are installed.
- CIS Docker Benchmark 1.9.0 covers the host, the daemon, images, and the container runtime. This skill applies the image and container-runtime controls in [security-baseline.md](security-baseline.md). It does not change the host or the daemon. Do not call the result a full CIS certification.
- Do not invent benchmark section numbers. Name the control the way the baseline names it, and cite a section number only after you have read it in the current benchmark.

## Image tags

Choose the newest stable tag that contains a version number. Reject `latest`, `stable`, `edge`, `main`, `master`, `nightly`, and pre-release tags (`rc`, `alpha`, `beta`, `dev`, `snapshot`, `preview`). Prefer a patch tag such as `1.27.4-alpine` over a floating minor tag.

Resolve the digest with `scripts/resolve-image-digest.sh`. The digest from `docker buildx imagetools inspect` is the multi-arch index digest, which is the right pin for `FROM`.
