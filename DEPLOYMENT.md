# Local Development Guide

> For architecture details and evaluation Q&A, see [ARCHITECTURE.md](ARCHITECTURE.md) and [EVALUATION.md](EVALUATION.md).

## Prerequisites

| Tool | Install |
|---|---|
| Docker | [docker.com](https://docs.docker.com/get-docker/) |
| Kind | `brew install kind` |
| Helm | `brew install helm` |
| kubectl | `brew install kubectl` |

## Quick Start

```bash
make up
```

This single command:
1. Creates a Kind cluster
2. Installs Envoy Gateway (Gateway API provider)
3. Builds the Docker image
4. Loads it into the cluster
5. Deploys the service with Helm
6. Runs endpoint tests to verify everything works

## Access the App

```bash
kubectl port-forward -n ping-pong svc/ping-pong 8080:80 &

# Health check (no auth required)
curl http://localhost:8080/health

# Ping/Pong (auth required)
curl -H "Authorization: Bearer dev-secret-token" http://localhost:8080/ping
curl -H "Authorization: Bearer dev-secret-token" http://localhost:8080/pong
```

## Commands

| Command | What it does |
|---|---|
| `make up` | Full setup from scratch (default: 2 replicas) |
| `make up REPLICAS=5` | Full setup with custom replica count |
| `make restart` | Rebuild image + redeploy (after code changes) |
| `make test` | Run tests, linting, and security scanning |
| `make down` | Delete the Kind cluster |

## Development Workflow

```bash
# 1. Start the environment
make up

# 2. Make code changes to main.go

# 3. Rebuild and redeploy (fast — reuses existing cluster)
make restart

# 4. Test your changes
kubectl port-forward -n ping-pong svc/ping-pong 8080:80 &
curl -H "Authorization: Bearer dev-secret-token" http://localhost:8080/ping

# 5. Run full test suite before pushing
make test

# 6. Clean up when done
make down
```

## What `make test` Installs

If not already present on your machine, `make test` automatically installs:

- **golangci-lint** (v2.12.1) — Go linter
- **govulncheck** — Go vulnerability scanner
- **hadolint** — Dockerfile linter

## Secrets in Local Dev

The local environment uses a dev token (`dev-secret-token`) passed via `--set` at deploy time. This is not a real secret — it only validates that the authentication flow works (secret mounted → app reads it → token comparison).

In staging and production, secrets are managed by the External Secrets Operator syncing from a cloud secret store. See [architecture.md](architecture.md) for details.

## Troubleshooting

**Pods stuck in `ContainerCreating`:**
```bash
kubectl describe pod -n ping-pong -l app.kubernetes.io/name=ping-pong
```

**Check pod logs:**
```bash
kubectl logs -n ping-pong -l app.kubernetes.io/name=ping-pong --tail=50
```

**View pod distribution across nodes:**
```bash
kubectl get pods -n ping-pong -o wide
```

**Port 8080 already in use:**
```bash
lsof -i :8080 | awk 'NR>1 {print $2}' | xargs kill
```

**Start fresh:**
```bash
make down && make up
```
