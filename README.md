# Secure Docker container skill

This project is a Cursor Agent Skill. When a prompt includes `creates a new docker container named x`, the agent creates that container: `x` is the name in the prompt. It asks for the workload, network exposure, outbound access, storage, and configuration keys before it writes anything. It then pins the newest patched base image by digest and applies current container hardening practice.

You can also invoke it with `/create-docker-container`.

## What you get

The agent writes `containers/<name>/` with a Dockerfile, a Compose file, an ignore file, and a how-to FAQ. The running container is checked before the agent says it is done.

The container is set up to:

- run as a non-root user
- keep a read-only root filesystem
- drop every Linux capability and block new privileges
- avoid privileged mode, host namespaces, and the Docker socket
- set memory, CPU, process, and file limits
- publish ports on `127.0.0.1` only, on port 1024 or higher
- restart only on failure, with log rotation and a real healthcheck

The agent looks up the current Docker Engine stable release and the current CIS Docker Benchmark each time. The snapshot in the skill is not a substitute for that lookup. Host and daemon settings are left unchanged.

## Requirements

Docker Engine with Compose v2 and BuildKit, on the machine where the container is created. The agent stops if Docker is missing.

Secret values stay in a gitignored `.env`. The chat is asked for key names only.

## Check the skill

The validator tests do not need a running Docker daemon:

```bash
bash .cursor/skills/create-docker-container/scripts/test-validator.sh
```
