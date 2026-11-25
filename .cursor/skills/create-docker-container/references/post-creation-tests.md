# Post-creation verification tests

Run these **after** the Dockerfile, Compose project, build, and optional start are finished. The agent must not mark the container done until every required row passes or is explicitly skipped with a documented reason.

## Command

From the workspace root:

```bash
bash <skill>/scripts/run-container-tests.sh \
  --project containers/<container-name> \
  --image <service>:local \
  [--started] \
  [--allow-public-ports] [--allow-root-entrypoint] [--internal-network]
```

- Use `--started` when the user chose to build and start the container.
- Omit `--image` only when no image was built (rare); the scan row becomes `SKIP`.
- Pass the same validator flags the interview allowed.

Exit **0** when every row is `PASS` or acceptable `SKIP`/`WARN` (scan skipped with no scanner). Exit **1** when any row is `FAIL`.

## Result table (required in chat and HOWTO)

The script prints a markdown table. Copy it into the final reply and into `HOWTO.md` under **Verification results** (token `__TEST_RESULTS_TABLE__`).

Columns:

| Column | Meaning |
| --- | --- |
| **Test** | What was checked |
| **Result** | `PASS`, `FAIL`, `SKIP`, `WARN`, or `WAIT` |
| **If this fails** | One-line remediation (from the script; expand using [security-baseline.md](security-baseline.md) for static/runtime ids) |

## Tests performed

| Test | When | If this fails |
| --- | --- | --- |
| Host Docker versions | Always (daemon required for live tests; use fixture only in skill self-tests) | Upgrade to Engine ≥ 29.9.1 and containerd ≥ 2.4.2 ([engine-upgrade.md](engine-upgrade.md)), or stop and patch the host before production. |
| Compose config | Always | Fix YAML or field errors in `compose.yml`; run `docker compose config` until it is quiet. |
| Static hardening | Always | Fix each `FAIL` from `validate-container.sh --static-only`; use the matching id in [security-baseline.md](security-baseline.md). |
| Local image exists | When `--image` is set | Run `docker compose build`; fix the Dockerfile until the build succeeds and the tag exists. |
| Container running | When `--started` | `docker compose up -d`; read `docker logs <name>` and fix the entrypoint or dependencies. |
| Runtime hardening | When `--started` | Fix compose drift, then `docker compose up -d --force-recreate`; re-run the validator without `--static-only`. |
| Healthcheck healthy | When `--started` | Fix the healthcheck command or the app; wait for the start period; on `WAIT`, re-run tests up to three times. |
| Vulnerability scan | When `--image` is set | Install Trivy, Grype, or Scout; patch the base or packages; do not downgrade the digest to hide CVEs on the newest pin. |

## Agent reply

After the HOWTO FAQ, include:

1. One sentence: overall **passed** or **failed**.
2. The **verification table** from the script.
3. If any `FAIL`, list the failing test names and the next command to run (from the table), not a generic “fix errors.”