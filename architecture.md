# Architecture

## Overview

This repository contains a production-ready CI/CD pipeline for a Go ping-pong HTTP server. The stack includes:

- **Multi-arch Docker images** built on parallel native runners (amd64 + arm64)
- **Helm-based deployment** using a reusable common chart pattern
- **External Secrets Operator** for production secrets management (no secrets in git)
- **Gateway API ingress** (HTTPRoute) instead of deprecated nginx-ingress
- **Automated versioning** via Release Please and conventional commits
- **Supply chain security** with Trivy scanning, govulncheck, SBOM generation, and a scratch base image

## Requirements Implementation

### Security Requirements

| Requirement | How it's handled | Where |
|---|---|---|
| **No containers running as root** | `USER 65534:65534` in Dockerfile sets the runtime user to `nobody`. Kubernetes enforces `runAsNonRoot: true` + `runAsUser: 65534` in the pod security context — if any container tries to run as root, the kubelet refuses to start it. CI integration test verifies this on every PR. | `Dockerfile:19`, `charts/common/values.yaml:87-91`, `.github/workflows/pr.yaml:164-171` |
| **All images must pass security scans** | Every image is scanned with Trivy (CRITICAL/HIGH severity, `exit-code: 1`) at multiple stages: filesystem scan on PR, built image scan in integration test, and per-architecture image scan in release pipeline. Additionally, `govulncheck` scans Go dependencies at call-graph level and `hadolint` validates the Dockerfile. | `.github/workflows/pr.yaml:59-65,101-107`, `.github/workflows/release.yaml:43-49,77-83` |
| **No critical/high vulnerabilities released to production** | Trivy image scans with `exit-code: 1` gate both the amd64 and arm64 builds in the release pipeline. The scans run *before* `create-manifest`, so a vulnerable image can never become part of a published multi-arch manifest. The release is blocked and no tag is pushed to the registry. | `.github/workflows/release.yaml:43-49,77-83` (run before `create-manifest` at line 85) |
| **No secrets in codebase** | No secret values exist anywhere in the repository. Staging and production use External Secrets Operator to sync secrets from a cloud store (AWS Secrets Manager / Akeyless) into Kubernetes Secrets. Local dev and CI use throwaway test tokens passed via `--set` at deploy time — these are not real secrets and are only used to validate the auth mechanism. | `charts/common/templates/externalsecret.yaml`, `charts/common/templates/secret.yaml`, `Makefile:5` |
| **Proper filesystem isolation** | `readOnlyRootFilesystem: true` prevents all writes to the container filesystem. `capabilities.drop: [ALL]` removes every Linux capability. `allowPrivilegeEscalation: false` blocks privilege escalation via setuid/kernel exploits. The scratch base image has no shell, no package manager, and no OS utilities. CI integration test verifies all of these on every PR. | `charts/common/values.yaml:93-98`, `Dockerfile:14` (scratch), `.github/workflows/pr.yaml:164-171` |

### Kubernetes Requirements

| Requirement | How it's handled | Where |
|---|---|---|
| **Zero-downtime deployments** | Rolling update strategy with `maxUnavailable: 0` and `maxSurge: 1` — the old pod is only removed after the new pod passes readiness checks. Startup probe (`initialDelaySeconds: 12`, `failureThreshold: 12`, `periodSeconds: 5`) gives the app 72 seconds to start. Readiness probe ensures traffic only reaches healthy pods. Graceful shutdown (SIGTERM handling with 5s drain) ensures in-flight requests complete before the pod exits. | `charts/common/values.yaml:100-104` (strategy), `charts/common/values.yaml:51-57` (startup probe), `main.go:230-244` (graceful shutdown) |
| **ARM64 architecture preferred** | Node affinity with `preferredDuringSchedulingIgnoredDuringExecution` (weight 100) for `kubernetes.io/arch: arm64`. Pods prefer ARM64 nodes (e.g., AWS Graviton for better price/performance) but still schedule on x86 if no ARM nodes are available. Multi-arch images ensure the correct binary runs on either architecture. | `deploy/ping-pong/values.yaml:92-101` |
| **No direct internet access (use ingress/proxy)** | Service type is `ClusterIP` (no external IP). External traffic enters only through the Gateway API (HTTPRoute → Gateway → Service). In local dev, Envoy Gateway serves as the proxy. In production, AWS Load Balancer Controller terminates TLS and routes to the cluster. Pods have no direct internet exposure. | `charts/common/templates/service.yaml` (ClusterIP), `charts/common/templates/httproute.yaml`, `docs/local/gateway.yaml` |
| **Cluster can pull from registry** | Images are pushed to GitHub Container Registry (GHCR) with public visibility. The release workflow authenticates with `GITHUB_TOKEN` to push images. For private registries, the service account supports `imagePullSecrets` annotations (e.g., IRSA for ECR). | `.github/workflows/release.yaml:23-27` (GHCR login), `charts/common/templates/serviceaccount.yaml` (annotations support) |

### CI/CD Requirements

| Requirement | How it's handled | Where |
|---|---|---|
| **Multi-architecture builds (x86/ARM64)** | Parallel native runners: `ubuntu-latest` builds amd64, `ubuntu-24.04-arm64` builds arm64. No QEMU emulation — each architecture builds at native speed. Both images are scanned independently with Trivy before being merged into a multi-arch manifest list. The container runtime on each node automatically pulls the matching architecture. | `.github/workflows/release.yaml:17-83` (parallel build jobs), `.github/workflows/release.yaml:85-110` (manifest creation) |
| **Images stored in GitHub Container Registry** | All images push to `ghcr.io/tomer-zino/ping-pong` using the `GITHUB_TOKEN` for authentication. Each release produces architecture-specific images (tagged `v1.0.0-amd64`, `v1.0.0-arm64`) and multi-arch manifests (tagged `v1.0.0` and `sha-abc123f`). | `.github/workflows/release.yaml:12-13` (registry/image env vars), `.github/workflows/release.yaml:97-110` (manifest tags) |
| **Versioned releases with tags** | Release Please automates SemVer versioning via conventional commits (`feat:` = minor, `fix:` = patch, `BREAKING CHANGE` = major). It opens a Release PR with a generated changelog, and creates a git tag + GitHub Release when merged. No manual version bumping needed. Image tags use immutable SemVer (`v1.2.0`) + commit SHA (`sha-abc123f`). No `latest` tag — mutable tags break reproducibility. | `.github/workflows/release-please.yaml`, `.github/workflows/release.yaml:97-110` (tagging) |
| **Both container and binary releases** | The release workflow produces: (1) multi-arch Docker images (linux/amd64 + linux/arm64), (2) cross-compiled Go binaries for 4 platforms (linux/darwin × amd64/arm64), and (3) a CycloneDX SBOM. Binaries and SBOM are uploaded as GitHub Release assets alongside the container images. | `.github/workflows/release.yaml:112-175` (binaries + SBOM + upload) |

## Code Quality Fixes

The original application code had several issues caught by the CI pipeline during validation:

### Go Version Upgrade (1.24 → 1.25.9)

The assignment specified Go 1.24, but `govulncheck` flagged 5 known CVEs in the Go 1.24 stdlib:

- **GO-2026-4869** — X.509 certificate verification bypass in `crypto/x509`
- **GO-2026-4868** — X.509 name constraint bypass in `crypto/x509`
- **GO-2026-4870** — TLS 1.3 KeyUpdate DoS in `crypto/tls`
- **GO-2026-4602** — FileInfo sandbox escape in `os`
- **GO-2026-4601** — IPv6 host literal parsing issue in `net/url`

All five are fixed in Go 1.25.x only — no 1.24.x patches exist since Go 1.24 has reached end-of-life. Upgrading to Go 1.25 was the only option to eliminate these vulnerabilities, which is the correct decision for a production deployment.

The version was further pinned to Go 1.25.9 (the latest patch) after `govulncheck` detected 13 additional stdlib CVEs in Go 1.25.0 (crypto/x509, crypto/tls, net/url, encoding/asn1). Pinning to a specific patch version in `go.mod`, `Dockerfile`, and all CI workflows ensures consistent vulnerability-free builds across local development and CI.

### Unchecked Error Returns

`golangci-lint` (errcheck) flagged several unchecked error return values in the original code:

- `json.NewEncoder(w).Encode(...)` in `authMiddleware` (lines 65, 81) — JSON encoding to the HTTP response writer can fail if the connection is closed
- `file.Close()` in `readSecretFromFile` (line 42) — deferred close can fail, especially on network filesystems
- `fmt.Fprint(w, html)` in `rootHandler` (line 377) — writing to the HTTP response writer can fail

All were wrapped with proper error handling and logging. While these errors are unlikely in practice, handling them is correct Go practice and demonstrates attention to code quality.

### Redundant Newline

`go vet` flagged `fmt.Println` with a string argument ending in `\n` — since `Println` already appends a newline, this produced a double newline. Fixed by removing the trailing newline from the raw string literal.

### Graceful Shutdown

The original code used `log.Fatal(http.ListenAndServe(...))` which does not handle OS signals. When Kubernetes sends `SIGTERM` during a rolling update, the process was killed immediately with a non-zero exit code, causing pods to show `Error` status during termination.

The fix replaces `ListenAndServe` with a pattern that:
1. Starts the HTTP server in a goroutine
2. Listens for `SIGTERM` and `SIGINT` signals
3. On signal, calls `server.Shutdown()` with a 5-second timeout to drain in-flight requests
4. Exits cleanly with code 0

This ensures:
- **No `Error` status** on terminating pods — Kubernetes sees a clean exit
- **No dropped requests** during rolling updates — in-flight requests complete before the process stops
- **Works with scratch image** — no shell or init process needed, signal handling is in the Go binary itself

The startup probe was also configured with `initialDelaySeconds: 12` to account for the application's 10-second startup delay, preventing false `Unhealthy` warnings during pod initialization.

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
- `USER 65534:65534` (nobody) -- the container never runs as root. UID 65534 is the well-known `nobody` user in Linux — the highest UID before the 16-bit overflow, universally mapped to a user that owns no files and has no privileges. It's the standard convention for minimal-privilege containers (used by Google's distroless images, Kubernetes official examples, and security benchmarks). Since scratch has no `/etc/passwd`, the UID doesn't resolve to a name, but the kernel and Kubernetes only enforce the numeric ID.

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

Five parallel jobs run on every pull request:

1. **Go Test & Lint** -- `go test -race`, `go vet`, golangci-lint
2. **Dockerfile Lint** -- hadolint for Dockerfile best practices
3. **Security Scan** -- govulncheck for Go dependency CVEs + Trivy filesystem scan
4. **Helm Lint** -- `helm lint`, dependency build, template rendering test
5. **Integration Test** -- Full end-to-end validation:
   - Builds the Docker image
   - Scans the image with Trivy (CRITICAL/HIGH gate)
   - Spins up a Kind cluster with Envoy Gateway
   - Deploys the service with Helm
   - Tests all endpoints (health, ping, pong, unauthorized access)
   - Verifies security context (non-root, read-only fs, capabilities dropped)

#### Production: Ephemeral PR Environments

The in-CI Kind cluster validates functionality, but in a production setup you would deploy each PR to an **ephemeral environment** on the shared cluster for more realistic testing:

1. **PR opened** -- CI builds and pushes the image tagged with `pr-<number>` to the registry
2. **Namespace provisioned** -- A controller (e.g., ArgoCD ApplicationSet with PR generator, or a custom operator) creates a dedicated namespace `pr-<number>` with:
   - The service deployed with the PR image tag
   - An HTTPRoute with a unique hostname (e.g., `pr-123.dev.example.com`)
   - Secrets synced via ESO from a shared dev secret store
   - Resource quotas to prevent runaway PR environments from affecting the cluster
3. **PR updated** -- Image is rebuilt, ArgoCD auto-syncs the new tag
4. **PR merged/closed** -- Namespace and all resources are automatically deleted

Benefits over in-CI Kind clusters:
- Tests against real infrastructure (load balancers, DNS, TLS, ESO)
- Other team members can access the PR environment for manual testing
- Can run longer-lived tests (performance, soak tests)
- Shared dependencies (databases, message queues) can be available

The trade-off is complexity -- you need namespace lifecycle management, DNS automation, and resource cleanup. Tools like ArgoCD ApplicationSets (with PR generators), Crossplane, or a custom queue-based controller (similar to the pattern used at scale) handle this well.

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

### Local (Kind + Envoy Gateway)

The local Gateway infrastructure lives in `docs/local/gateway.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy-gateway
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: envoy-gateway
  namespace: envoy-gateway-system
spec:
  gatewayClassName: envoy-gateway
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
```

Envoy Gateway is installed via Helm into the Kind cluster and acts as the Gateway API provider. Traffic flow: `kubectl port-forward` → Gateway (port 80) → HTTPRoute → Service → Pods.

### Production (EKS + AWS Load Balancer Controller)

In production, the infrastructure team manages the Gateway resource. The only changes are the GatewayClass controller and TLS configuration:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: aws-alb
spec:
  controllerName: gateway.networking.k8s.io/aws-alb-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: production
  namespace: ingress-system
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:...
spec:
  gatewayClassName: aws-alb
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - name: production-cert
      allowedRoutes:
        namespaces:
          from: All
```

**What stays the same:** The HTTPRoute in the Helm chart (`charts/common/templates/httproute.yaml`) is identical in both environments. It references the Gateway via `parentRef` — the only difference is the gateway name. This is configured in `deploy/ping-pong/values.yaml` so no chart code changes are needed between environments.

**Traffic flow in production:** Client → AWS ALB (TLS termination) → Gateway → HTTPRoute → Service → Pods.

## Image Tagging Strategy

| Tag | Example | Purpose |
|---|---|---|
| SemVer | `v1.2.0` | Immutable release tag used in deployments |
| Commit SHA | `sha-abc123f` | Traceability back to exact source commit |

**No `latest` tag.** Mutable tags are bad practice -- they break reproducibility, make rollbacks unreliable, and can mask which code is actually running.

Tags are automatically updated in `deploy/ping-pong/values.yaml` by the release workflow (GitOps pattern).

## Security

The assignment requires: no containers running as root, all images pass security scans, no critical/high vulnerabilities released to production, no secrets in codebase, and proper filesystem isolation.

### Container Security Context

The Helm common chart enforces a hardened security context on every pod via `charts/common/values.yaml`:

**`runAsNonRoot: true` + `runAsUser: 65534`** -- The container runs as the `nobody` user (UID 65534), never as root. This is enforced at two levels: the Dockerfile (`USER 65534:65534`) sets the default, and the Kubernetes `podSecurityContext` enforces it even if a different image is used. If any process in the pod tries to run as root, Kubernetes will refuse to start it.

**`readOnlyRootFilesystem: true`** -- The container's root filesystem is mounted read-only. The process cannot write to disk at all -- no dropping malware binaries, no modifying configuration files, no writing scripts. The only writable path is the explicitly mounted secret volume (`/secrets`). Since the Go binary is stateless and reads its configuration from environment variables and the mounted secret, it has no need to write to the filesystem.

**`allowPrivilegeEscalation: false`** -- Blocks the process from gaining more privileges than its parent process. Without this, an attacker who compromises the process could use `setuid` binaries or kernel exploits to escalate from user 65534 to root. This setting closes that path entirely.

**`capabilities.drop: [ALL]`** -- Linux capabilities are fine-grained subsets of root privileges. By default, containers receive a subset of these capabilities (e.g., `NET_RAW` for raw sockets, `SYS_ADMIN` for mount/namespace operations, `NET_BIND_SERVICE` for binding to ports below 1024). Dropping ALL means the process has zero special kernel privileges. The Go HTTP server listens on port 8080 (unprivileged) and makes no system calls that require capabilities.

Combined with the scratch base image (no shell, no package manager, no OS utilities), these controls provide defense in depth: even if the Go process is compromised via a vulnerability, the attacker has no tools, no write access, no capabilities, and no way to escalate privileges.

The CI integration test (`pr.yaml`) verifies these security properties on every pull request by inspecting the running pod's security context in the Kind cluster.

### Security Scanning Pipeline

Vulnerabilities are blocked at multiple stages, ensuring no critical/high CVEs reach production:

| Stage | Tool | What it scans | When |
|---|---|---|---|
| PR validation | govulncheck | Go dependency CVEs at call-graph level | Every PR |
| PR validation | Trivy (filesystem) | Source code and dependencies | Every PR |
| PR validation | Trivy (image) | Built Docker image in integration test | Every PR |
| PR validation | hadolint | Dockerfile best practices | Every PR |
| Release | Trivy (image, amd64) | Built amd64 image before manifest | Every release tag |
| Release | Trivy (image, arm64) | Built arm64 image before manifest | Every release tag |

All Trivy scans use `exit-code: 1` with `severity: CRITICAL,HIGH`, meaning the pipeline fails and no image is published if vulnerabilities are found. The release pipeline scans each architecture independently *before* the `create-manifest` job runs, so a vulnerable image can never become part of a multi-arch manifest.

### Secrets Management

No secrets exist in plaintext anywhere in the repository. The secret token reaches the pod as a Kubernetes Secret mounted at `/secrets/token` in all environments -- the app code is identical everywhere. Only the **creation mechanism** for that Kubernetes Secret differs:

#### How the Secret Reaches the Pod Per Environment

| Environment | Mechanism | Where the real value lives |
|---|---|---|
| Local dev (`make up`) | Helm `--set` | Hardcoded dev token in Makefile — any value works for testing |
| CI integration test | Helm `--set` | Hardcoded test token in workflow — validates auth flow, not real secrets |
| Staging | External Secrets Operator | Cloud secret store (AWS Secrets Manager / Akeyless) |
| Production | External Secrets Operator | Cloud secret store (AWS Secrets Manager / Akeyless) |

Local dev and CI don't need real secrets -- they only validate that the auth flow works (secret mount → read → token comparison). Any token value works for testing. Staging and production use the same architecture: ESO syncing from a cloud secret store.

#### External Secrets Operator (Staging + Production)

The [External Secrets Operator](https://external-secrets.io/) (ESO) runs as a controller in the cluster and syncs secrets from a cloud provider directly into Kubernetes Secrets. This is used in all deployed environments (staging and production).

**How it works:**

```
┌─────────────────────────────────────────────────────────┐
│  Infrastructure team                                     │
│  Creates secret in AWS Secrets Manager / Akeyless        │
│  Configures ClusterSecretStore (one-time cluster setup)  │
└─────────────────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────────────────┐
│  ExternalSecret CRD (in Helm chart)                      │
│  Declares: "sync key 'ping-pong/token' from store X      │
│             into K8s Secret 'ping-pong' key 'token'"     │
│         ↓ (ESO controller reconciles)                   │
│  K8s Secret created/updated automatically                │
│  Pod mounts it at /secrets/token                         │
└─────────────────────────────────────────────────────────┘
```

**Toggled via values:**
```yaml
# deploy/ping-pong/values.yaml
common:
  externalSecrets:
    enabled: true
    secretStoreRef: cluster-secret-store
    data:
      - secretKey: token
        remoteRef:
          key: ping-pong/token
```

When `externalSecrets.enabled: true`, the Helm chart renders an `ExternalSecret` CRD instead of a plain Kubernetes Secret. The ESO controller watches this CRD and creates the actual Secret by pulling the value from the cloud store.

**Why ESO for all deployed environments:**
- **No secrets in git** — not even encrypted. The secret value lives only in the cloud store.
- **Automatic rotation** — ESO polls or watches for changes. When a secret rotates in AWS Secrets Manager, the Kubernetes Secret updates automatically without a redeploy.
- **Audit logging** — every secret access is logged by the cloud provider (CloudTrail, etc.)
- **Centralized access control** — IAM policies control who can read/write secrets, not shared encryption keys.
- **Same architecture everywhere** — staging and production use identical infrastructure, reducing environment drift.

**Why local dev and CI don't use ESO:**
- No cloud infrastructure available in a Kind cluster or CI runner
- Real secret values aren't needed — testing only validates the mechanism (mount → read → compare)
- `--set` is simpler and has no dependencies

### Security Summary

| Measure | What it does |
|---|---|
| Non-root container (`USER 65534`) | Prevents privilege escalation even if the process is compromised |
| scratch base image | Zero OS packages = zero base image CVEs |
| Read-only root filesystem | Prevents runtime file writes (e.g., malware dropping binaries) |
| All capabilities dropped | Removes all Linux capabilities (NET_RAW, SYS_ADMIN, etc.) |
| Privilege escalation blocked | Prevents setuid/kernel exploits from escalating to root |
| Trivy image scan gate | CRITICAL/HIGH vulnerabilities block both PR and release pipelines |
| govulncheck | Detects known CVEs in Go dependencies at the call-graph level |
| hadolint | Enforces Dockerfile best practices (pinned versions, minimal layers) |
| CycloneDX SBOM | Full software bill of materials for supply chain transparency |
| External Secrets Operator | Secrets synced from cloud store; no plaintext or encryption keys in git or cluster |
| CI security verification | Integration test validates security context on every PR |

## Scaling Strategy

The ping-pong service is **stateless** -- it holds no in-memory state between requests, reads configuration from environment variables and a mounted secret, and has no local storage. This makes horizontal scaling straightforward.

**Current setup:**
- `replicaCount: 2` in values (minimum for high availability)
- `make up REPLICAS=N` allows testing with any replica count locally
- Rolling update with `maxUnavailable: 0` ensures zero capacity loss during deploys

**Production scaling options:**

| Approach | Trigger | Best for |
|---|---|---|
| HPA (Horizontal Pod Autoscaler) | CPU/memory utilization thresholds | General-purpose, built into Kubernetes |
| HPA with custom metrics | Request rate, latency (via Prometheus adapter) | Traffic-driven scaling |
| KEDA (Event-Driven Autoscaler) | Queue depth, HTTP rate, cron schedule | More flexible triggers, scale-to-zero |

**Example HPA configuration:**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ping-pong
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ping-pong
  minReplicas: 2
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

**Why the service scales well:**
- No shared state between pods — each request is independent
- Read-only filesystem — no local writes to coordinate
- Resource limits defined (200m CPU, 128Mi memory) — scheduler knows capacity
- Startup probe gives pods time to initialize before receiving traffic

## Cloud Deployment Considerations

### Compute & Orchestration

- **EKS + ArgoCD**: ArgoCD watches this repo and auto-syncs `deploy/ping-pong/` to the cluster. The `update-deploy-tag` CI job pushes the new image tag to `deploy/ping-pong/values.yaml` on every release, closing the GitOps loop. ArgoCD detects the change and rolls out automatically.
- **AWS Graviton instances**: ARM64 node affinity (weight 100) prefers Graviton instances which offer ~40% better price/performance for compute workloads. The multi-arch image ensures the correct binary runs transparently.
- **Multi-region with ArgoCD ApplicationSets**: Deploy to multiple clusters from a single repo using ApplicationSets with cluster generators. Each region gets its own deployment but shares the same chart and values.

### Networking

- **AWS Load Balancer Controller**: Serves as the Gateway API provider on EKS. The HTTPRoute manifest stays identical -- only the Gateway parentRef changes. TLS termination happens at the ALB with ACM certificates.
- **ECR cross-region replication**: For global deployments, replicate images to regional ECR registries to reduce pull latency and avoid cross-region data transfer costs.

### Secrets

- **ESO + AWS Secrets Manager / Akeyless**: Toggle `externalSecrets.enabled: true` and point to a ClusterSecretStore. No SOPS keys needed on the cluster. Secrets rotate automatically without redeployment.

## Image Versioning & Lifecycle

### Tagging Strategy

Every release produces two immutable tags:

| Tag | Example | Purpose |
|---|---|---|
| SemVer | `v1.2.0` | Human-readable release version, used in deployments |
| Commit SHA | `sha-abc123f` | Traceability back to exact source commit |

**No `latest` tag.** Mutable tags are bad practice — they break reproducibility, make rollbacks unreliable, and can mask which code is actually running. If a pod restarts and pulls `latest`, it might get a different version than its neighbors.

### GitOps Tag Update

The release workflow automatically updates the image tag in `deploy/ping-pong/values.yaml` and pushes to main. This creates a single source of truth for what version is deployed:

```
Release tag created (v1.2.0)
  → release.yaml builds + pushes images
  → update-deploy-tag job updates values.yaml with v1.2.0
  → ArgoCD detects change → rolls out new version
```

Rollback is a single `git revert` of the tag update commit — ArgoCD auto-syncs back to the previous version.

### Removing Old Images

GHCR lifecycle policies should be configured to automatically clean up old images:

```
Repository Settings → Packages → ping-pong → Settings → Manage versions
```

**Recommended retention rules:**
- Delete untagged manifests older than 7 days (leftover from failed builds)
- Delete architecture-specific tags (`v1.0.0-amd64`, `v1.0.0-arm64`) older than 30 days (the multi-arch manifest references them by digest, but old versions accumulate)
- Keep all SemVer-tagged manifests for at least 90 days (rollback window)
- Keep SHA-tagged manifests for 30 days (debugging window)

**Why cleanup matters:**
- GHCR charges for storage above free tier limits
- Old images may contain known vulnerabilities — keeping them available increases risk of accidental use
- A clean registry makes it easier to identify what's actually deployed

For ECR (production), configure lifecycle policies via Terraform:
```hcl
resource "aws_ecr_lifecycle_policy" "cleanup" {
  repository = "ping-pong"
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Remove untagged images after 7 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 7
      }
      action = { type = "expire" }
    }]
  })
}
```

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

### How Multi-Arch Image Selection Works

The `create-manifest` job produces a **Docker manifest list** -- a single image reference that contains pointers to multiple architecture-specific images:

```
ghcr.io/tomer-zino/ping-pong:v1.0.0  (manifest list)
├── linux/amd64 → sha256:abc123...    (built on ubuntu-latest)
└── linux/arm64 → sha256:def456...    (built on ubuntu-24.04-arm64)
```

**Who selects the right image:** The container runtime (containerd/CRI-O) on each Kubernetes node. When the kubelet pulls an image, the runtime reads the manifest list, matches `os/architecture` against the node's platform, and pulls only the matching layers. This is part of the [OCI Image Index](https://github.com/opencontainers/image-spec/blob/main/image-index.md) specification -- no configuration needed.

**This means it works out of the box on:**

| Platform | Architecture | What gets pulled |
|---|---|---|
| EKS on x86 instances | amd64 | `ping-pong:v1.0.0` → amd64 layers |
| EKS on Graviton instances | arm64 | `ping-pong:v1.0.0` → arm64 layers |
| Mixed cluster (x86 + Graviton) | both | Each node pulls its matching arch |
| Mac (Apple Silicon) with Kind/Docker | arm64 | `ping-pong:v1.0.0` → arm64 layers |
| Mac (Intel) with Kind/Docker | amd64 | `ping-pong:v1.0.0` → amd64 layers |
| Windows with Docker Desktop (WSL2) | amd64 | `ping-pong:v1.0.0` → amd64 layers |
| CI runners (ubuntu-latest) | amd64 | `ping-pong:v1.0.0` → amd64 layers |

**No pod spec changes needed.** The same deployment manifest works everywhere -- you specify the image tag and the runtime handles architecture selection transparently.

### Local Development vs Released Images

In local development (`make up`), Docker builds a **single-arch image** matching the developer's machine:
- Apple Silicon Mac → arm64 image
- Intel Mac / Linux x86 → amd64 image

This is loaded directly into Kind via `kind load docker-image` -- no registry pull, no manifest list. Multi-arch is only relevant for **released images** pushed to GHCR, where the image needs to run on any target cluster regardless of architecture.

### ARM64 Node Affinity

The deployment values include a preferred node affinity for arm64:

```yaml
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: kubernetes.io/arch
              operator: In
              values:
                - arm64
```

This tells the scheduler to **prefer** ARM64 nodes (e.g., AWS Graviton -- better price/performance) but still schedule on x86 if no ARM nodes are available. It's a soft preference, not a hard requirement, so the service runs on any architecture.
