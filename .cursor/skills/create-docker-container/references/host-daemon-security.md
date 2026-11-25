# Host and Docker daemon configuration

This skill does not change the host or the daemon. Copy the checklist into each container's `HOWTO.md` so the operator can close gaps on the machine that runs Docker.

## Docker socket protection

- Treat `/var/run/docker.sock` as root-equivalent. Limit membership in the `docker` group to trusted administrators.
- Never bind `docker.sock` into a container. **Validated on the container project** (`no-docker-sock`).
- Do not expose the daemon on unauthenticated TCP `2375`. Remote API access must use TLS on `2376` with client certificates.

## User namespace remapping

- Enable `userns-remap` in `/etc/docker/daemon.json` when the host policy allows it, so container `root` maps to an unprivileged host user.
- Rootless Docker is an acceptable alternative when userns remapping is not available.

## Logging and auditing

- Set daemon log rotation (`log-driver` options with `max-size` and `max-file`). Container projects already rotate service logs; the daemon still needs its own policy.
- Monitor `/etc/docker`, `daemon.json`, and `/var/lib/docker` with auditd or an equivalent.
- Forward container logs to a central system when production policy requires it.

## Keep Engine and runc updated

- Do not run hardened workloads on Engine **below 29.9.1** or bundled containerd **below 2.4.2**; earlier releases have known security vulnerabilities.
- Track the current stable Docker Engine release and patch the host promptly.
- Update `containerd` and `runc` with Engine releases to pick up container escape fixes.
- Record Engine and containerd versions from `docker version` in `HOWTO.md`. Remind the operator when they lag the security floor or the current stable release.

## Default seccomp and MAC

- Do not disable AppArmor, SELinux, or seccomp on the host.
- Container compose files must not set `seccomp=unconfined`, `apparmor=unconfined`, or `label:disable`. **Validated** (`no-unconfined`).