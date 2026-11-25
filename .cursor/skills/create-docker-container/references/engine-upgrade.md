# Upgrade Docker Engine and containerd

Run this path only after the user confirms they want to upgrade the host. The skill does not upgrade silently.

Bundled **containerd** ships with Docker Engine. Upgrading Engine to **29.9.1 or higher** usually upgrades containerd to **2.4.2 or higher** as well. After any upgrade, re-run:

```bash
bash scripts/check-docker-versions.sh
```

## Linux (Debian, Ubuntu, and derivatives)

Follow the current Docker install guide: https://docs.docker.com/engine/install/ubuntu/

Typical package upgrade after the official repo is configured:

```bash
sudo apt-get update
sudo apt-get install --only-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

On RHEL-compatible systems use `dnf upgrade docker-ce` (or the distro package name) per https://docs.docker.com/engine/install/.

## Linux (other)

Use the install page for the distribution: https://docs.docker.com/engine/install/

## macOS (Docker Desktop)

Open **Docker Desktop → Check for updates** or download the current release from https://docs.docker.com/desktop/release-notes/

## Windows (Docker Desktop)

Same as macOS: **Docker Desktop → Check for updates** or https://docs.docker.com/desktop/release-notes/

## Verify

```bash
docker version
bash <skill>/scripts/check-docker-versions.sh
```

Record the new Engine and containerd versions in the container `HOWTO.md`. If the check still fails, stop and troubleshoot before building hardened containers on a vulnerable daemon.