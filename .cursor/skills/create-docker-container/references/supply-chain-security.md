# Image build and supply chain security

The agent applies every control below when it writes the Dockerfile and build settings. The validator enforces the items marked **validated**.

## Minimal or distroless base images

Prefer, in order:

1. **Distroless** or **Docker Hardened Images** when the workload matches an official variant.
2. **`-slim`**, **`alpine`**, or another **minimal** tag from the publisher when distroless is not an option.
3. A full OS image only as a **builder stage**, never as the final runtime stage unless the user accepts the exception in the interview.

The final stage must not ship a login shell, SSH, or a package manager unless the process truly needs one. Remove `curl`, `wget`, and compilers from the runtime image. **Validated** (`minimal-runtime`, `no-dev-tooling-final`).

## Pin base image digests

Every `FROM` except `scratch` uses `repository@sha256:<64 hex>`. The human tag sits in the comment above the line. No mutable tags such as `latest`. **Validated** (`from-digest`, `from-no-latest`, `from-tag-comment`).

## Multi-stage builds

When the project compiles code, bundles assets, or installs development dependencies, use at least two stages: a **builder** with tools, and a **runtime** that receives only binaries, static assets, or runtime libraries. **Validated** (`multistage-when-compile`).

## Secrets in images

- Never put secrets in `ENV`, `ARG`, or layers via `COPY` of `.env`, keys, or token files.
- Build-time secrets use BuildKit: `RUN --mount=type=secret,id=<name>` and a `secrets` block in Compose `build` when needed.
- Runtime secrets use a gitignored `.env`, Docker secrets, or an external manager (Vault, cloud secret stores). They must not appear in committed files. **Validated** (`no-secret-env`, `no-copy-secrets`).

## Non-root user

`USER` in the Dockerfile and `user:` in Compose name the same unprivileged identity. Create `65532:65532` when the base image runs as root. **Validated** (`user-nonroot`).

## Continuous image scanning

After each build:

1. Run `scripts/scan-image.sh <image:tag>`.
2. Record the scanner, summary, and any unresolved critical or high findings in `HOWTO.md`.
3. Do not ship a new tag to replace a digest solely to hide scanner results on the newest patched base.
4. When the user wants CI, add `assets/ci-container-scan.yml` to `.github/workflows/` (or their CI) so pipelines fail on fixable critical or high CVEs.

If no scanner is installed locally, say so in the FAQ and include the scan commands for Trivy, Grype, and Docker Scout.