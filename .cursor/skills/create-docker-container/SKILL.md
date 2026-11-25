---
name: create-docker-container
description: 'Create a hardened Docker container and its Compose project. Use this skill whenever the prompt includes "creates a new docker container named x", where x is the container name. Also use it when the user asks to create a new Docker container, scaffold a secure container, or harden a new container configuration. Ask for every input the container needs, target the current Docker Engine stable release and the current CIS Docker Benchmark, pin the newest patched base image by digest, apply container security best practices, and finish with a how-to-use FAQ.'
compatibility: "Requires Docker Engine with Compose v2 and BuildKit on the machine where the container is created. Re-check the current stable Engine and the current CIS Docker Benchmark at creation time."
metadata:
  version: "1.2.0"
icon: shield
color: green
---

# Create a secure Docker container

Follow this skill in order. Create the container. Do not stop at generic Docker advice. Do not write files, pull images, or start a container until the interview in this skill is answered.

The phrase `creates a new docker container named x` is the trigger. The `x` is the container name written in that prompt, not the literal letter x, unless the user actually asked for a container named x.

Examples:

- `creates a new docker container named billing-api` creates a container named `billing-api`.
- `creates a new docker container named "x"` creates a container named `x`.

## 1. Read the baseline

Read these references before choosing an image or writing a Dockerfile:

- [references/versions.md](references/versions.md)
- [references/security-baseline.md](references/security-baseline.md)
- [references/supply-chain-security.md](references/supply-chain-security.md)
- [references/host-daemon-security.md](references/host-daemon-security.md)

The version file is a snapshot. Look up the current Docker Engine stable release and the current CIS Docker Benchmark, and trust the lookup when it is newer than the snapshot.

## 2. Take the name from the prompt

Take the first token after `named`. Strip surrounding quotes and trailing punctuation. Accept only a name that matches `^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$`.

If the prompt has no name, or the name is not valid, ask for a valid name and wait. Do not invent one.

Use that exact string as the Docker container name and as Compose `container_name`. Use the lowercased name, with underscores turned into hyphens, as the Compose service name, project name, and network name. Put the project in `containers/<container-name>/` at the workspace root. Do not put it inside this skill directory.

If a container or Compose project already uses that name, ask whether to replace it or pick another name. Do not remove the existing container until the user chooses replace.

## 3. Check Docker

Run `docker compose version` and `docker info`. Run the minimum security version check:

```bash
bash <skill>/scripts/check-docker-versions.sh
```

The script requires **Docker Engine ≥ 29.9.1** and **bundled containerd ≥ 2.4.2** on the daemon. Earlier releases have known security vulnerabilities. Constants live in [references/versions.md](references/versions.md).

- If the Docker client is missing, stop. Point the user at the current stable Engine install documentation (`https://docs.docker.com/engine/install/`). Do not fake a container.
- If the client exists and the daemon is down, say so. You may write the project files after the interview, and you must not claim the container is running.
- When the check exits **1** (`WARN` / `FAIL`), stop the workflow. Explain which component is below the minimum. Use AskQuestion (or ask in the reply and wait) with these options:
  - **Upgrade Engine and containerd now**, then re-run the check. Only after the user confirms, follow [references/engine-upgrade.md](references/engine-upgrade.md) for their OS (package upgrade or Docker's official install steps). Do not run destructive host commands without confirmation. After upgrade, run `check-docker-versions.sh` again; do not create the container until it passes or the user explicitly chooses to continue without upgrading.
  - **Continue without upgrading** — accept the security risk and proceed with the interview.
  - **Stop** — end the skill until the host is patched.
- Compare the installed Engine with the current stable release from the lookup in step 1 as well. If it is older than current stable but still ≥ 29.9.1, mention that in the FAQ; only ask to continue when it is below **29.9.1** unless the user already chose to continue without upgrading.
- Do not set `DOCKER_CONTENT_TRUST`. Content trust was retired. Pin images by digest instead.

Record the installed Engine and containerd versions, the minimum security floor (29.9.1 / 2.4.2), the current stable Engine from lookup, the Compose version, and the CIS benchmark version you actually looked up. Those values go in the FAQ.

## 4. Ask for the inputs

Ask before creating anything. If the user already answered these in the conversation, use those answers and do not ask again. Otherwise use the AskQuestion tool in one call. If that tool is not available, ask in the reply and stop. Do not fill in answers yourself, and do not create the container in the same turn as the questions.

Ask these questions. Omit a question only when the user's prompt already answered it.

1. `workload` — What should this container run?
   - A static site on an unprivileged port
   - The application already in this workspace
   - An upstream image the user will name
   - A background worker with no published port
   - A database or other stateful service
2. `exposure` — How should other machines reach it?
   - Do not publish a port
   - Publish on localhost only (`127.0.0.1`)
   - Publish on all interfaces
3. `outbound` — May the container open outbound connections?
   - Yes, allow outbound access
   - No, put it on an internal network
4. `storage` — What data must survive a restart?
   - Nothing
   - A named Docker volume
   - A bind mount of a host directory
5. `configuration` — What configuration does the process need?
   - None
   - The user selects Other and types key names only, comma-separated. Tell them not to type secret values.
6. `launch` — What should happen after the files are written?
   - Build the image and start the container
   - Write the files and do not start it

Ask a second round only for facts the first answers made necessary, then wait again:

- Upstream image: which repository.
- Database: which engine, and a memory limit (512m is often too small; offer 512m, 1g, 2g, and Other).
- Existing application: inspect the workspace first and confirm what you found. If there is no application, say so and ask which other workload they want.
- Published port: container port and host port, after you know the image. Default both to the image port when it is 1024 or higher.
- Volume or bind mount: container path, and the host path for a bind mount. Default the mount to read-only. Ask before making it writable.
- Engine or containerd below 29.9.1 / 2.4.2: upgrade now, continue without upgrading, or stop.
- Installed Engine is older than current stable but meets the security floor: note in FAQ only unless the user cares.
- Name collision: replace or choose another name.
- The image can only start as root: accept that exception or pick another image. See the baseline.

Apply these defaults without asking, and record them in the FAQ. Mention them when you ask anything they affect:

| Setting | Default |
| --- | --- |
| Run user | The image's non-root user. If it has none, create uid/gid `65532:65532`. |
| Memory | `512m` |
| CPUs | `1.0` |
| Process limit | `256` |
| Open-file limit | `1024` |
| Temp directory | `tmpfs` `/tmp`, 64m, `rw,noexec,nosuid,nodev` |
| Restart | `on-failure:5` |
| Logs | `json-file`, 10m, 3 files |
| Init process | enabled |
| Published ports | bound to `127.0.0.1`, host port 1024 or higher, process listens on 1024 or higher |
| Secrets | key names in `.env.example`; values only in gitignored `.env` |

Do not publish or listen on a port below 1024. Map a high container port instead, for example `127.0.0.1:8080:8080`. That removes any need for `NET_BIND_SERVICE`.

## 5. Choose and pin the image

Prefer a currently maintained image that already runs as non-root, including a Docker Hardened Image when one exists for the workload. Otherwise use the publisher's official image and enforce a non-root user in the Dockerfile you write.

Look up the newest stable tag. It must contain a version number. Do not use `latest`, `stable`, `edge`, `main`, `master`, a pre-release, or a tag with no version number. If the lookup fails, ask the user which tag to pin. Do not guess.

Pin it with this skill's script, from the skill directory:

```bash
bash scripts/resolve-image-digest.sh <repository>:<tag>
```

Use the single line it prints as `FROM`. Put the human-readable tag in a comment above that line. Pin every stage, including the builder. `scratch` needs no digest. Keep `# syntax=docker/dockerfile:1` so the Dockerfile uses Docker's current stable frontend.

If `cosign` is installed and the publisher documents a signature, verify it and record the result. If it is not installed, record that signature verification was skipped. Do not skip the digest pin.

## 6. Write the project

Read the templates in [assets/](assets/) and write a concrete project. Replace every placeholder. The finished files must pass the validator.

Write these files in `containers/<container-name>/`:

- `Dockerfile`
- `compose.yml`
- `.dockerignore`
- `.gitignore` ignoring `.env`
- `.env.example` when the user named configuration keys, and a gitignored `.env` copied from it with empty values
- `HOWTO.md`, written in the last step

Use a multi-stage build whenever the workload compiles code or runs `npm`/`yarn`/`pnpm` build steps. The final stage must be a slim, Alpine, or distroless-style base; keep full OS images in builder stages only. Pair `apt-get update` with `apt-get install` in the same `RUN`. Pin native packages. Use `COPY`, not `ADD`. Do not install OpenSSH, a shell, or curl just to make debugging or the healthcheck easier. The healthcheck must observe the real process, not `exit 0`.

For build-time secrets, use BuildKit `RUN --mount=type=secret,id=...` and wire secrets in Compose `build.secrets` when needed. Never assign secret values to `ENV` or `ARG`, and never `COPY` `.env` or key files into a layer.

Compose `image` for the locally built container is `<service>:local`. The pinned upstream image belongs in `FROM`, not in an unpinned `image:` field.

Set `container_name` to the requested name. Use the short port form `"127.0.0.1:<host>:<container>"` when a port is published. Set the network `internal: true` only when the user refused outbound access.

Never write a secret value into the Dockerfile, the image, the Compose file, the chat reply, or a committed file. Configuration values stay in `.env`.

## 7. Validate, build, and start

From the workspace root, with `<skill>` as the directory that contains this `SKILL.md`:

```bash
bash <skill>/scripts/validate-container.sh --project containers/<container-name> --static-only
```

Fix every `FAIL` and run it again. Read the matching row in [references/security-baseline.md](references/security-baseline.md) and apply that fix. Do not weaken a control to get a pass.

A control may be relaxed only when the interview recorded the user's acceptance:

- `--allow-public-ports` after they chose all interfaces. The FAQ must say the port is reachable from the network.
- `--allow-root-entrypoint` after they accepted an image that can only start as root. Keep every other control, including read-only root, dropped capabilities, and `no-new-privileges`.

Pass `--internal-network` when they refused outbound access.

If they chose to start the container, build and start with Compose from `containers/<container-name>/`:

```bash
docker compose up -d
```

Then run the validator without `--static-only`. A pass counts only from that live inspect. Never pass `--inspect-json`. If the output contains `WAIT`, the healthcheck is still starting: wait and run the validator again, at most three times. If it is still `WAIT`, stop and say the healthcheck did not become healthy. Do not describe the container as done while the validator exits non-zero.

After a successful build, run:

```bash
bash <skill>/scripts/scan-image.sh <service>:local
```

Record the scanner name, pass or fail, and any critical or high CVEs in the FAQ. If no scanner is installed, state that and list install commands for Trivy, Grype, and Docker Scout. Offer the CI template [assets/ci-container-scan.yml](assets/ci-container-scan.yml) when the user wants pipeline enforcement. Do not roll back to an older tag to hide findings on the newest patched base.

Paste the host and daemon checklist from [references/host-daemon-security.md](references/host-daemon-security.md) into `HOWTO.md` under **What does this not protect?** so operators know how to harden the machine that runs Docker.

If they chose not to start it, the static validator is the gate. Say that the running container has not been checked yet, and put the start command in the FAQ.

## 8. List the how-to FAQ

Write `containers/<container-name>/HOWTO.md` from [references/faq.md](references/faq.md). Replace every `__TOKEN__` with the real value. Keep a `<!-- IF ... -->` block only when that condition is true, and delete the marker comments. Do not leave a `__TOKEN__` or a marker comment in the file.

The final reply leads with the FAQ. Start with one sentence naming the container and the pinned image, then the FAQ itself, including the hardening checks. Do not end the turn without that FAQ.

## Refusals

Do not create a privileged container, share the host network, PID, or IPC namespace, mount the Docker socket or other sensitive host paths, set the user to root without an accepted exception, add Linux capabilities, disable AppArmor or seccomp, or use an unpinned `latest` tag. Tell the user which control you are keeping and ask how they want to proceed inside this baseline.

Do not change the Docker daemon, host firewall, or user-namespace settings as part of this skill. Those are host controls. Describe them in the FAQ and leave them alone.

Do not commit the project, and do not commit `.env`, unless the user asks.
