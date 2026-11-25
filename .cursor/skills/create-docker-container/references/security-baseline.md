# Container security baseline

Apply every control below. The validator id is what `scripts/validate-container.sh` prints. When a check fails, fix it as this table says and run the validator again.

Controls are grouped by where they apply:

| Phase | What it covers |
| --- | --- |
| **Image build and supply chain** | Dockerfile, build args, layers, digests, multi-stage layout, secrets in images |
| **Container runtime** | Compose and `docker inspect` after start |
| **Host and daemon** | Out of scope for file changes; checklist in [host-daemon-security.md](host-daemon-security.md) and the FAQ |

## Image build and supply chain

| Id | Control | Required fix |
| --- | --- | --- |
| `dockerfile-syntax` | Use Docker's current stable Dockerfile frontend. | First instruction comment is `# syntax=docker/dockerfile:1`. |
| `from-digest` | Pin every base image by digest. | `FROM repository@sha256:<64 hex>` on every stage except `scratch`. |
| `from-tag-comment` | Keep the human-readable tag next to the pin. | The comment immediately above each pinned `FROM` names the tag, including a dotted version such as `1.2.3`. |
| `from-no-latest` | Do not use a floating tag. | No `latest`. Choose the newest patched version tag, then pin its digest. |
| `minimal-runtime` | Prefer minimal final bases. | Final `FROM` is slim, Alpine, distroless, Docker Hardened, or an equivalent minimal runtime—not a full Ubuntu or Debian image. |
| `multistage-when-compile` | Multi-stage when building artifacts. | When the Dockerfile compiles or bundles with npm, cargo, go, make, mvn, gradle, or similar, use at least two stages and copy only outputs into the final stage. |
| `no-secret-env` | No secrets in ENV or ARG. | Remove `ENV`/`ARG` that assign passwords, tokens, or keys. Use BuildKit `RUN --mount=type=secret` at build time and runtime injection otherwise. |
| `no-copy-secrets` | No secret files in layers. | Do not `COPY` `.env`, keys, PEM files, or credential paths into the image. |
| `no-dev-tooling-final` | No compilers in the final stage. | Install `build-essential`, `build-base`, or equivalent only in a builder stage, not after the last `FROM`. |
| `user-nonroot` | Run as a non-root user. | `USER` in the Dockerfile and `user:` in Compose. Use the image's non-root user, or create `65532:65532`. |
| `no-add` | Do not use `ADD`. | Use `COPY`. |
| `no-dist-upgrade` | Do not upgrade the whole distro inside the image. | Delete `apt-get upgrade`, `apk upgrade`, and the equivalent. Pin the packages you install. |
| `no-ssh` | Do not install or run SSH in the container. | Remove OpenSSH and `sshd`. |

Continuous vulnerability scanning is not a static file check. After build, run `scripts/scan-image.sh <image-ref>` and record results in `HOWTO.md`. For CI, use [assets/ci-container-scan.yml](../assets/ci-container-scan.yml).

## Container runtime (Compose and live inspect)

| Id | Control | Required fix |
| --- | --- | --- |
| `healthcheck` | Check the real process. | A `HEALTHCHECK` or Compose `healthcheck` that fails when the service is down. Never `exit 0`. |
| `read-only` | Read-only root filesystem. | `read_only: true`, plus explicit writable mounts. |
| `no-new-privileges` | Block privilege escalation. | `security_opt: ["no-new-privileges:true"]`. |
| `cap-drop-all` | Drop every Linux capability. | `cap_drop: ["ALL"]` and an empty `cap_add`. |
| `no-cap-add` | Do not add capabilities back. | Listen on port 1024 or higher and publish that port. Do not add `NET_BIND_SERVICE`. |
| `no-privileged` | Do not run privileged. | No `privileged: true` and no `--privileged`. |
| `no-host-namespaces` | Do not share host namespaces. | No host network, PID, IPC, UTS, or user namespace. |
| `no-docker-sock` | Do not mount the Docker socket. | Remove any `docker.sock` mount. |
| `no-sensitive-mounts` | Do not mount sensitive host directories. | No bind of `/`, `/etc`, `/proc`, `/sys`, `/boot`, `/dev`, `/usr`, `/lib`, `/lib64`, or `/var/lib/docker`. |
| `no-shared-propagation` | Do not use shared mount propagation. | Remove shared propagation. |
| `no-unconfined` | Keep the default syscall and MAC profiles. | No `seccomp=unconfined`, `apparmor=unconfined`, or `label:disable`. Rely on the host's default seccomp and AppArmor or SELinux. |
| `memory-limit` | Bound memory. | `mem_limit`, default `512m`, higher only when the user asked. |
| `cpu-limit` | Bound CPU. | `cpus`, default `1.0`. |
| `pids-limit` | Bound process count. | `pids_limit`, default `256`. |
| `nofile-limit` | Set an open-file limit. | `ulimits.nofile` soft and hard `1024`. |
| `tmpfs-tmp` | Give `/tmp` a bounded noexec filesystem. | `tmpfs: ["/tmp:rw,noexec,nosuid,nodev,size=64m"]`. |
| `user-defined-network` | Use a user-defined bridge. | A named network with `driver: bridge`, not the default bridge and not `driver: host`. |
| `egress` | Match the outbound answer. | `internal: true` only when the user refused outbound access. Pass `--internal-network` in that case. |
| `restart-on-failure` | Restart only on failure, with a limit. | `restart: "on-failure:5"`. |
| `log-rotation` | Rotate logs. | `json-file` with `max-size: "10m"` and `max-file: "3"`. |
| `init` | Reap zombies. | `init: true`. |
| `container-name` | Use the requested name. | `container_name` equals the name from the prompt. |
| `port-bind` | Bind published ports to localhost. | `"127.0.0.1:<host>:<container>"`, both ports 1024 or higher. Public bind only with `--allow-public-ports`. |
| `runtime/running` | The container is running when the user asked to start it. | `docker compose up -d`, then inspect it. |
| `runtime/health` | The running healthcheck is healthy. | Fix the check or the app. `WAIT` means run the validator again. |
| `runtime/no-devices` | Do not pass host devices through. | Remove `devices`. |

Runtime ids prefixed with `runtime/` are the same controls observed from `docker inspect` after the container starts. Static ids are observed from the files. Both must pass when the container is started.

## Exceptions

Only two exceptions exist, and both require an explicit answer in the interview:

1. Public port bind (`--allow-public-ports`). The process still listens on an unprivileged port, the root filesystem stays read-only, and capabilities stay dropped.
2. An upstream entrypoint that can only start as root (`--allow-root-entrypoint`). Keep read-only root, `no-new-privileges`, and `cap_drop: ["ALL"]`. Say in the FAQ that the entrypoint starts as root and which image forced it.

Any other request that conflicts with this table is refused.

## Build rules the validator does not fully parse

- Do not run `apt-get update` in its own `RUN`. Install only the packages the final process needs, pinned to versions.
- Remove setuid and setgid binaries you do not need.
- Add OCI labels you can fill truthfully (`org.opencontainers.image.title`, `description`, `version`). Do not invent a source URL or a license.
- The image's own `USER` and Compose `user` should be the same non-root identity.