# Contributing

This repository is meant to stay easy to run locally and easy to inspect. Keep changes focused and make sure the full stack still works with `docker compose`.

## Local Workflow

1. Run `make check` for static validation.
2. Run `make up` to start the stack.
3. Run `make smoke` to verify traces, logs, metrics, service graph data, and exemplars.
4. Use `make down` when done.

## Change Guidelines

- Keep the stack local-first. Do not add production-only complexity unless it is clearly isolated.
- Prefer official Grafana and OpenTelemetry configuration patterns.
- Keep Grafana provisioning declarative so a fresh start stays reproducible.
- Avoid committing generated state under `data/`.
- If you change telemetry semantics, update the README and smoke test together.

## Pull Requests

- Describe the user-visible effect of the change.
- Note any version bumps and why they were needed.
- Include the validation commands you ran locally.

