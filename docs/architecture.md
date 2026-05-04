# Architecture

## Overview

This repository contains a production-ready CI/CD pipeline for a Go ping-pong HTTP server. The stack includes:

- **Multi-arch Docker images** built on parallel native runners (amd64 + arm64)
- **Helm-based deployment** using a reusable common chart pattern
- **SOPS-encrypted secrets** with an External Secrets Operator (ESO) toggle for production
- **Gateway API ingress** (HTTPRoute) instead of deprecated nginx-ingress
- **Automated versioning** via Release Please and conventional commits
- **Supply chain security** with Trivy scanning, govulncheck, SBOM generation, and a scratch base image

## Code Quality Fixes

The original application code had several issues caught by the CI pipeline during validation:

### Go Version Upgrade (1.24 → 1.25)

The assignment specified Go 1.24, but `govulncheck` flagged 5 known CVEs in the Go 1.24 stdlib:

- **GO-2026-4869** — X.509 certificate verification bypass in `crypto/x509`
- **GO-2026-4868** — X.509 name constraint bypass in `crypto/x509`
- **GO-2026-4870** — TLS 1.3 KeyUpdate DoS in `crypto/tls`
- **GO-2026-4602** — FileInfo sandbox escape in `os`
- **GO-2026-4601** — IPv6 host literal parsing issue in `net/url`

All five are fixed in Go 1.25.x only — no 1.24.x patches exist since Go 1.24 has reached end-of-life. Upgrading to Go 1.25 was the only option to eliminate these vulnerabilities, which is the correct decision for a production deployment.

### Unchecked Error Returns

`golangci-lint` (errcheck) flagged several unchecked error return values in the original code:

- `json.NewEncoder(w).Encode(...)` in `authMiddleware` (lines 65, 81) — JSON encoding to the HTTP response writer can fail if the connection is closed
- `file.Close()` in `readSecretFromFile` (line 42) — deferred close can fail, especially on network filesystems
- `fmt.Fprint(w, html)` in `rootHandler` (line 377) — writing to the HTTP response writer can fail

All were wrapped with proper error handling and logging. While these errors are unlikely in practice, handling them is correct Go practice and demonstrates attention to code quality.

### Redundant Newline

`go vet` flagged `fmt.Println` with a string argument ending in `\n` — since `Println` already appends a newline, this produced a double newline. Fixed by removing the trailing newline from the raw string literal.

## Dockerfile

The Dockerfile uses a multi-stage build:

```
golang:1.25-alpine (builder) -> scratch (final)
```

**Why scratch:** A scratch image contains literally nothing -- no shell, no OS packages, no package manager. This means zero CVEs from the base image and the smallest possible attack surface. The only files in the final image are the static Go binary and CA certificates.

Key decisions:
- `CGO_ENABLED=0` produces a fully static binary with no libc dependency, required for scratch
- `-ldflags="-s -w"` strips debug symbols and DWARF info, reducing binary size
- CA certificates copied from the builder stage to support outbound HTTPS
- `USER 65534:65534` (nobody) -- the container never runs as root

## Helm Common Chart

The `charts/common/` directory contains a reusable Helm chart that any microservice can consume. A service deploys by creating a `deploy/<service>/` directory with:

- `Chart.yaml` -- declares a dependency on the common chart
- `values.yaml` -- service-specific configuration

**What the common chart provides:**

| Template | Description |
|---|---|
| `deployment.yaml` | Pod spec with security context, rolling updates (`maxUnavailable: 0`), startup/readiness/liveness probes, optional secret volume mount |
| `service.yaml` | ClusterIP service |
| `httproute.yaml` | Gateway API HTTPRoute (conditional) |
| `secret.yaml` | Kubernetes Secret from values (conditional, for local/CI) |
| `externalsecret.yaml` | ExternalSecret CRD (conditional, for production) |
| `serviceaccount.yaml` | ServiceAccount with optional annotations (e.g., IRSA) |

**Adding a new service** requires only a new `deploy/<service>/` directory with Chart.yaml and values.yaml. No chart code changes needed.

## Secrets Management

Two-tier approach that keeps the same Kubernetes Secret interface regardless of environment:

### Local / CI: SOPS + age + helm-secrets

- Secret values are encrypted in-repo (`values-secrets.enc.yaml`) using SOPS with age encryption
- The age private key is stored locally for development and as a GitHub Actions secret for CI
- Deployed with `helm secrets install` which decrypts on-the-fly
- Secrets never appear in plaintext in git

### Production: External Secrets Operator

- ESO syncs secrets from AWS Secrets Manager or Akeyless into Kubernetes Secrets
- Toggled via `externalSecrets.enabled: true` in values
- The pod always mounts the same Kubernetes Secret -- only the creation mechanism differs
- Infrastructure team manages the SecretStore/ClusterSecretStore; app team just references keys

## CI/CD Pipeline

Three GitHub Actions workflows:

### `pr.yaml` -- PR Validation

Four parallel jobs run on every pull request:

1. **Go Test & Lint** -- `go test -race`, `go vet`, golangci-lint
2. **Dockerfile Lint** -- hadolint for Dockerfile best practices
3. **Security Scan** -- govulncheck for Go dependency CVEs + Trivy filesystem scan
4. **Helm Lint** -- `helm lint`, dependency build, template rendering test

### `release-please.yaml` -- Automated Versioning

Runs on push to `main`. Release Please analyzes conventional commit messages and:
- Opens/updates a Release PR with a generated changelog
- Bumps the version according to commit types (feat = minor, fix = patch, breaking = major)
- Creates a git tag and GitHub Release when the Release PR merges

### `release.yaml` -- Build & Publish

Triggered by `v*` tags. Jobs:

1. **build-amd64** -- Builds and pushes amd64 image on `ubuntu-latest`, runs Trivy scan
2. **build-arm64** -- Builds and pushes arm64 image on `ubuntu-24.04-arm64`, runs Trivy scan
3. **create-manifest** -- Merges arch-specific images into multi-arch manifests (SemVer + SHA tags)
4. **build-binaries** -- Cross-compiles Go binaries (linux/darwin x amd64/arm64)
5. **release-assets** -- Uploads binaries + CycloneDX SBOM to the GitHub Release
6. **update-deploy-tag** -- Updates the image tag in `deploy/ping-pong/values.yaml` and pushes to main (GitOps)

Trivy image scan is a **security gate**: if CRITICAL or HIGH vulnerabilities are found, the build fails and no manifest is created.

## Gateway API

This project uses the Kubernetes Gateway API (GA since v1.0) instead of the deprecated nginx-ingress controller.

**Why Gateway API:**
- **Provider-agnostic**: The same HTTPRoute manifest works with Envoy Gateway (local Kind cluster) and AWS Load Balancer Controller (EKS) -- only the Gateway resource changes
- **Better separation of concerns**: Infrastructure team manages the Gateway (listeners, TLS), app team manages HTTPRoute (routing rules)
- **Future-proof**: Gateway API is the successor to Ingress, with broader community adoption

The ping-pong service defines an HTTPRoute that routes `/ping`, `/pong`, `/health`, and `/` through the gateway to the ClusterIP service.

## Image Tagging Strategy

| Tag | Example | Purpose |
|---|---|---|
| SemVer | `v1.2.0` | Immutable release tag used in deployments |
| Commit SHA | `sha-abc123f` | Traceability back to exact source commit |

**No `latest` tag.** Mutable tags are bad practice -- they break reproducibility, make rollbacks unreliable, and can mask which code is actually running.

Tags are automatically updated in `deploy/ping-pong/values.yaml` by the release workflow (GitOps pattern).

## Security Summary

| Measure | What it does |
|---|---|
| Non-root container (`USER 65534`) | Prevents privilege escalation even if the process is compromised |
| scratch base image | Zero OS packages = zero base image CVEs |
| Read-only root filesystem | Prevents runtime file writes (e.g., malware dropping binaries) |
| All capabilities dropped | Removes all Linux capabilities (NET_RAW, SYS_ADMIN, etc.) |
| Trivy image scan gate | CRITICAL/HIGH vulnerabilities block the release pipeline |
| govulncheck | Detects known CVEs in Go dependencies at the call-graph level |
| hadolint | Enforces Dockerfile best practices (pinned versions, minimal layers) |
| CycloneDX SBOM | Full software bill of materials for supply chain transparency |
| SOPS-encrypted secrets | No plaintext secrets in git; age encryption with controlled key distribution |

## Production Considerations

These are design decisions and patterns ready for a production deployment:

- **EKS + ArgoCD**: ArgoCD watches this repo and auto-syncs `deploy/ping-pong/` to the cluster. The `update-deploy-tag` CI job closes the GitOps loop.
- **ESO + AWS Secrets Manager / Akeyless**: Toggle `externalSecrets.enabled: true` and point to a ClusterSecretStore. No SOPS keys needed on the cluster.
- **AWS Load Balancer Controller**: Serves as the Gateway API provider on EKS. The HTTPRoute manifest stays identical -- only the Gateway parentRef changes.
- **ECR cross-region replication**: For global deployments, replicate images to regional ECR registries to reduce pull latency and avoid cross-region data transfer.
- **HPA or KEDA**: Autoscale based on request rate, CPU, or custom metrics. The service is stateless so horizontal scaling is straightforward.
- **GHCR lifecycle policies**: Set retention rules to auto-delete untagged manifests and images older than N days, keeping storage costs low.
- **Multi-region with ArgoCD ApplicationSets**: Deploy to multiple clusters from a single repo using ApplicationSets with cluster generators.

## Multi-Architecture Builds

The release pipeline builds amd64 and arm64 images on **parallel native runners** rather than using QEMU emulation.

**Why native runners over QEMU:**

| | Native Runners | QEMU Emulation |
|---|---|---|
| Build speed | Native performance | 5-10x slower (CPU emulation) |
| Reliability | No emulation quirks | Occasional segfaults, flaky builds |
| Language support | Works for any stack | Works for any stack |
| Cost | Two runner minutes | One runner, but much longer |

The pipeline structure:
1. `build-amd64` runs on `ubuntu-latest` (x86)
2. `build-arm64` runs on `ubuntu-24.04-arm64` (native ARM)
3. `create-manifest` merges both into a single multi-arch Docker manifest

This is a production-grade pattern -- it is language-agnostic (not relying on Go's cross-compilation), and each architecture gets a Trivy scan before the manifest is created.
