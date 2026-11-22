# syntax=docker/dockerfile:1

# example.invalid/app:1.2.3
FROM example.invalid/app@sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08

USER 65532:65532

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD ["/app/healthcheck"]

ENTRYPOINT ["/app/serve"]
