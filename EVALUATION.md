# Evaluation Q&A

Answers to the evaluation questions for the ping-pong deployment assignment.

---

## 1. Deployment Strategy

**Approach:** GitOps with Helm + ArgoCD.

The deployment is driven by a single source of truth: `deploy/ping-pong/values.yaml` in this git repository. When a release is created, the CI pipeline builds the image, pushes it to GHCR, and updates the image tag in `values.yaml`. ArgoCD (or any GitOps controller) detects the change and rolls it out.

**Rolling update configuration:**
- `maxUnavailable: 0` — no existing pod is removed until a new one is ready
- `maxSurge: 1` — one new pod is created at a time
- Startup probe with `initialDelaySeconds: 12` gives the app time to initialize (it has a 10s startup delay)
- Readiness probe gates traffic — only healthy pods receive requests
- Graceful shutdown (SIGTERM handling, 5s drain) ensures in-flight requests complete before pod termination

**Zero-downtime guarantee:** At every point during a rollout, there are always `replicaCount` healthy pods serving traffic. The new pod must pass its readiness probe before the old pod is terminated.

**Rollback:** `git revert` the tag update commit. ArgoCD syncs back to the previous version automatically — no manual `helm rollback` or `kubectl` commands needed.

---

## 2. Scaling Strategy

The service is **stateless** — no in-memory state, no local storage, no sessions. Each request is independent. This makes horizontal scaling trivial.

**Local testing:**
```bash
make up REPLICAS=10  # Test with 10 replicas
```

**Production autoscaling with HPA:**
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

**Why it scales well:**
- No shared state between pods — each handles requests independently
- Read-only filesystem — no coordination needed
- Resource requests/limits defined — scheduler knows capacity per pod
- Rolling update with `maxUnavailable: 0` — scaling events don't reduce available capacity

**Alternative: KEDA** — for more advanced triggers (queue depth, HTTP rate, cron schedules, scale-to-zero).

---

## 3. Security Measures

### Container Security
| Measure | Purpose |
|---|---|
| `USER 65534:65534` (nobody) | Container never runs as root |
| `scratch` base image | Zero OS packages = zero base image CVEs, no shell for attackers |
| `readOnlyRootFilesystem: true` | No runtime file writes (malware can't drop binaries) |
| `allowPrivilegeEscalation: false` | Blocks setuid/kernel exploits |
| `capabilities.drop: [ALL]` | Zero Linux capabilities (no raw sockets, no mounts) |
| `runAsNonRoot: true` (pod level) | Kubernetes refuses to start the pod if any container tries root |

### Supply Chain Security
| Tool | Stage | What it catches |
|---|---|---|
| Trivy (filesystem) | PR | CVEs in source code and dependencies |
| Trivy (image) | PR + Release | CVEs in built container image |
| govulncheck | PR | Go CVEs at call-graph level (not just imported) |
| hadolint | PR | Dockerfile anti-patterns |
| CycloneDX SBOM | Release | Full software bill of materials for auditing |

### Secrets
- **No secrets in git** — not even encrypted
- External Secrets Operator syncs from AWS Secrets Manager / Akeyless into K8s Secrets
- Local dev uses throwaway tokens (`--set` at deploy time) — validates the auth mechanism, not real secrets
- The pod always reads from the same mount path (`/secrets/token`) — environment-agnostic code

---

## 4. CI/CD Pipeline

Three workflows:

### PR Validation (`pr.yaml`)
Five parallel jobs on every pull request:
1. **Go Test & Lint** — `go test -race`, `go vet`, golangci-lint
2. **Dockerfile Lint** — hadolint
3. **Security Scan** — govulncheck + Trivy filesystem scan
4. **Helm Lint** — `helm lint`, template rendering test
5. **Integration Test** — builds image, deploys to Kind cluster, tests all endpoints, verifies security context

### Automated Versioning (`release-please.yaml`)
- Runs on push to `main`
- Analyzes conventional commits (`feat:` = minor, `fix:` = patch, `BREAKING CHANGE` = major)
- Opens a Release PR with generated changelog
- Creates git tag + GitHub Release when merged

### Build & Publish (`release.yaml`)
Triggered by `v*` tags:
1. Build amd64 image (native runner) + Trivy scan
2. Build arm64 image (native runner) + Trivy scan
3. Create multi-arch manifest (only if both scans pass)
4. Cross-compile Go binaries (linux/darwin x amd64/arm64)
5. Upload binaries + SBOM to GitHub Release
6. Update image tag in `values.yaml` (GitOps trigger)

**Security gate:** Trivy scan with `exit-code: 1` blocks the manifest creation if CRITICAL/HIGH CVEs are found. Vulnerable images are never published.

---

## 5. Multi-Architecture Builds

**Approach:** Parallel native runners (no QEMU emulation).

```
build-amd64 (ubuntu-latest)     ──┐
                                   ├──→ create-manifest (multi-arch manifest list)
build-arm64 (ubuntu-24.04-arm64) ─┘
```

**Why native over QEMU:**
- Native speed vs 5-10x slower emulation
- No flaky segfaults from CPU emulation
- Each arch scanned independently before merge

**How it works at pull time:**

The `create-manifest` job produces an OCI Image Index (manifest list):
```
ghcr.io/tomer-zino/ping-pong:v1.0.0
├── linux/amd64 → sha256:abc123...
└── linux/arm64 → sha256:def456...
```

The container runtime (containerd) on each node reads the manifest list, matches the node's `os/architecture`, and pulls only the correct layers. No pod spec changes needed — the same image reference works everywhere:

| Platform | What gets pulled |
|---|---|
| EKS on x86 instances | amd64 layers |
| EKS on Graviton (arm64) | arm64 layers |
| Mac (Apple Silicon) + Docker | arm64 layers |
| Mac (Intel) + Docker | amd64 layers |

---

## 6. Versioning and Tagging Strategy

**Automated versioning:** Release Please analyzes conventional commit messages:
- `feat: add endpoint` → bumps minor (v1.1.0 → v1.2.0)
- `fix: handle timeout` → bumps patch (v1.2.0 → v1.2.1)
- `feat!: change API` or `BREAKING CHANGE:` → bumps major (v1.2.1 → v2.0.0)

**Image tags produced per release:**

| Tag | Example | Purpose |
|---|---|---|
| SemVer | `v1.2.0` | Human-readable, used in deployments |
| Commit SHA | `sha-abc123f` | Exact traceability to source |

**No `latest` tag.** Mutable tags break reproducibility — if a pod restarts, it might pull a different version than its neighbors.

**GitOps flow:**
```
Merge to main
  → Release Please opens Release PR with changelog
  → Merge Release PR → git tag v1.2.0 created
  → release.yaml builds images, pushes to GHCR
  → update-deploy-tag updates values.yaml with v1.2.0
  → ArgoCD detects change → rolls out
```

---

## 7. Going Cloud with EKS

### What changes from local (Kind) to EKS

| Component | Local (Kind) | EKS |
|---|---|---|
| Cluster | Kind on your machine | EKS managed control plane |
| Gateway provider | Envoy Gateway (Helm) | AWS Load Balancer Controller |
| TLS | None (port-forward) | ACM certificate on ALB |
| Secrets | `--set` dev token | ESO + AWS Secrets Manager |
| Registry | `kind load` (no registry) | GHCR or ECR |
| Deployment | `helm install` | ArgoCD (GitOps) |

### Deployment to EKS

1. **Cluster setup** (Terraform/eksctl):
   - EKS cluster with managed node groups (Graviton instances for arm64)
   - Install ArgoCD, AWS Load Balancer Controller, External Secrets Operator
   - Configure IRSA (IAM Roles for Service Accounts) for ESO and registry access

2. **Gateway API:**
   - Replace local Envoy GatewayClass with AWS ALB GatewayClass
   - The HTTPRoute in the Helm chart stays identical — only the `parentRef` gateway name changes (configured in values)

3. **GitOps:**
   - ArgoCD Application points to `deploy/ping-pong/` in this repo
   - Release pipeline updates image tag → ArgoCD auto-syncs
   - No manual `helm install` or `kubectl apply` — git is the single source of truth

4. **Networking:**
   - Client → Route 53 (DNS) → AWS ALB (TLS termination) → Gateway → HTTPRoute → Service → Pods
   - Network policies restrict pod-to-pod traffic (deny all except required paths)

---

## 8. Fast Global Image Pulls (AWS Solutions)

### Problem
Teams across the world pulling from a single-region registry face high latency and cross-region data transfer costs.

### Solution: ECR Cross-Region Replication

```
┌─────────────────────────────────────────────────┐
│  CI pushes to primary ECR (us-east-1)           │
│         ↓ (automatic replication)                │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐   │
│  │ eu-west-1 │  │ ap-south-1│  │ us-west-2 │   │
│  └───────────┘  └───────────┘  └───────────┘   │
│         ↑              ↑              ↑          │
│    EU clusters    Asia clusters   US-West clusters│
└─────────────────────────────────────────────────┘
```

**Configuration (Terraform):**
```hcl
resource "aws_ecr_replication_configuration" "global" {
  replication_configuration {
    rule {
      destination {
        region      = "eu-west-1"
        registry_id = data.aws_caller_identity.current.account_id
      }
      destination {
        region      = "ap-southeast-1"
        registry_id = data.aws_caller_identity.current.account_id
      }
    }
  }
}
```

**How nodes pull the closest replica:**
- Each EKS cluster is configured to pull from its local region's ECR endpoint (`<account>.dkr.ecr.<region>.amazonaws.com`)
- IRSA provides authentication — no image pull secrets needed
- If the local replica hasn't synced yet (new image), it falls back to the primary region

### Additional optimizations:
- **ECR pull-through cache** — proxy and cache upstream registries (e.g., GHCR) in ECR, reducing external dependencies
- **Image layer caching** — common base layers are stored once per region, only new layers transfer
- **VPC endpoints for ECR** — pulls stay on AWS private network, no internet transit

---

## 9. Managing Older and Stale Versions

### Image Lifecycle Policy

**GHCR (development/open source):**
- Delete untagged manifests after 7 days (failed builds)
- Delete arch-specific tags (`v1.0.0-amd64`) after 30 days (multi-arch manifest uses digest)
- Keep SemVer manifests for 90 days (rollback window)
- Keep SHA tags for 30 days (debugging window)

**ECR (production) — Terraform lifecycle policy:**
```hcl
resource "aws_ecr_lifecycle_policy" "cleanup" {
  repository = "ping-pong"
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only last 10 tagged releases"
        selection = {
          tagStatus     = "tagged"
          tagPatternList = ["v*"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}
```

### Why cleanup matters:
- **Cost** — registry storage charges accumulate with old images
- **Security** — old images contain known CVEs; keeping them available risks accidental use
- **Clarity** — a clean registry makes it obvious what's deployed and what's available for rollback

### Rollback considerations:
- Keep the last N releases (e.g., 10) for rollback capability
- Rollback is `git revert` on the tag update commit — ArgoCD syncs the previous version
- If the image has been cleaned up, re-run the release pipeline on that git tag to rebuild it

---
