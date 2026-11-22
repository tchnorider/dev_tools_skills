# How to use __CONTAINER_NAME__

Fill this in after the container is created. Replace every `__TOKEN__`. Keep a block wrapped in `<!-- IF NAME -->` ... `<!-- END IF NAME -->` only when that condition is true, and delete the marker comments. Drop any section that does not apply. Do not leave a token or a marker in `HOWTO.md`.

__CONTAINER_NAME__ runs __IMAGE_TAG__ pinned to `__IMAGE_REF__`. The process runs as `__RUN_USER__`. The project files are in `__PROJECT_DIR__`.

Resolved on __RESOLVED_ON__. Installed Docker Engine __ENGINE_INSTALLED__. Current stable Engine __ENGINE_STABLE__. Compose __COMPOSE_VERSION__. Image and runtime controls were checked against CIS Docker Benchmark __CIS_BENCHMARK__. This did not change the Docker host or the daemon.

<!-- IF EXCEPTIONS -->
Accepted exceptions: __EXCEPTIONS__
<!-- END IF EXCEPTIONS -->

## How do I start it?

```bash
docker compose -f __COMPOSE_FILE__ up -d
```

## How do I stop it?

```bash
docker compose -f __COMPOSE_FILE__ stop
```

The container stays on disk. Start it again with the command above.

## How do I restart it?

```bash
docker compose -f __COMPOSE_FILE__ restart
```

Restart does not rebuild the image. Use the rebuild steps after a file change.

## How do I see if it is running?

```bash
docker ps --filter name=^__CONTAINER_NAME__$
```

## How do I read the logs?

```bash
docker logs --tail 100 -f __CONTAINER_NAME__
```

Logs rotate at 10m, and three files are kept.

## How do I check health?

```bash
docker inspect --format '{{.State.Health.Status}}' __CONTAINER_NAME__
```

`healthy` means the healthcheck passed. `starting` means the start period is not over. `unhealthy` means the process is up and the check failed. Read the logs next.

## How do I open a shell?

<!-- IF SHELL -->
The image includes a shell. The process runs as `__RUN_USER__`:

```bash
docker exec -it --user __RUN_USER__ __CONTAINER_NAME__ __SHELL__
```

<!-- END IF SHELL -->
<!-- IF NO SHELL -->
This image has no shell on purpose. Use the logs and the health status. Do not rebuild it with a shell, curl, or SSH just to look around.
<!-- END IF NO SHELL -->

## Where does its data live?

<!-- IF VOLUME -->
Persistent data is in `__VOLUME_SOURCE__`, mounted on `__VOLUME_TARGET__` inside the container. The root filesystem is read-only, so the process can write only on mounts that were declared writable.

Stop the container before you copy the data:

```bash
docker compose -f __COMPOSE_FILE__ stop
```

<!-- IF BIND -->
The files are on the host at `__VOLUME_SOURCE__`. Copy that directory.
<!-- END IF BIND -->
<!-- IF NAMED VOLUME -->
The named volume is `__VOLUME_SOURCE__`. Copy it with a digest-pinned image that contains `tar`. Use the service image when it has `tar`. Otherwise resolve a current Alpine patch tag with `__RESOLVE_SCRIPT__` and use that printed reference as the image. Do not use `:latest`.

```bash
mkdir -p backup
docker run --rm \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --user __RUN_USER__ \
  --mount type=volume,source=__VOLUME_SOURCE__,target=/from,readonly \
  --mount type=bind,source="$(pwd)/backup",target=/to \
  __BACKUP_IMAGE__ \
  tar -C /from -cf /to/__CONTAINER_NAME__-backup.tar .
```

<!-- END IF NAMED VOLUME -->
<!-- END IF VOLUME -->
<!-- IF NO VOLUME -->
This container has no persistent storage. Files written under `/tmp` live in a 64m memory filesystem and disappear when the container is removed. The root filesystem is read-only.
<!-- END IF NO VOLUME -->

## How do I change the published port?

<!-- IF PORT -->
It publishes `__HOST_BIND__:__HOST_PORT__` to container port `__CONTAINER_PORT__`. Change the host side of that mapping in `__COMPOSE_FILE__`, then recreate the container:

```bash
docker compose -f __COMPOSE_FILE__ up -d
```

Keep the host side on `127.0.0.1` unless you intend the service to be reachable from the network. Keep both ports at 1024 or higher.
<!-- END IF PORT -->
<!-- IF NO PORT -->
This container does not publish a port. Add a `127.0.0.1:<host>:<container>` mapping only if the process listens inside the container, then recreate it and run the validator again.
<!-- END IF NO PORT -->

## How do I pass configuration?

<!-- IF ENV -->
Key names are listed in `__PROJECT_DIR__/.env.example`. Put values in `__PROJECT_DIR__/.env`, which is gitignored, then recreate the container. Do not put those values in the Dockerfile, the Compose file, or git.

```bash
docker compose -f __COMPOSE_FILE__ up -d
```

<!-- END IF ENV -->
<!-- IF NO ENV -->
This container was created with no extra configuration. To add some, list the key names, put the values in a gitignored `.env`, reference that file from Compose with `env_file`, and recreate the container. Do not bake values into the image.
<!-- END IF NO ENV -->

## How do I rebuild after a change?

```bash
docker compose -f __COMPOSE_FILE__ up -d --build
```

Then run the validator again.

## How do I update the base image?

Look up the newest patched tag again. Do not move to `:latest`. Pin the new digest:

```bash
bash __RESOLVE_SCRIPT__ <repository>:<tag>
```

Put the printed reference in every `FROM`, rebuild, and run the validator. If a scanner is installed, scan the new image and read the critical and high results before you keep it.

## How do I confirm it is still hardened?

```bash
__VALIDATOR_COMMAND__
```

Every line should say `PASS`. `FAIL` means the container drifted from the baseline. Fix the reported id using the skill's security baseline and run the command again. `WAIT` means the healthcheck is still in its start period.

__VALIDATOR_SUMMARY__

## How do I remove it?

```bash
docker compose -f __COMPOSE_FILE__ down
```

<!-- IF VOLUME -->
That command does not delete `__VOLUME_SOURCE__`. Add `--volumes` only when you mean to delete the data.
<!-- END IF VOLUME -->

## What should I never change?

- Do not set `privileged: true`, add capabilities, or remove `no-new-privileges`.
- Do not mount the Docker socket, the host's `/`, `/etc`, `/proc`, `/sys`, or `/var/lib/docker`.
- Do not switch the network, PID, or IPC namespace to `host`.
- Do not set the user to root unless you have accepted that exception for an image that cannot start any other way.
- Do not replace the digest pin with `:latest`.
- Do not put secrets in the image or in git.

## What does this not protect?

The container's own configuration was hardened. The Docker host and daemon were not. Review the current CIS Docker Benchmark host and daemon controls separately: who can talk to the Docker socket, whether the daemon runs rootless or with user namespaces, and how the host is patched. A container shares the host kernel, so a kernel vulnerability is outside what this FAQ changes.
