# Architecture Decisions & Reasoning

## Overview

This document explains the technical decisions behind TRDL's architecture. Each choice is justified with reasoning, alternatives considered, and trade-offs acknowledged. The goal is a PoC that demonstrates production-grade HA patterns while remaining simple enough to evaluate, extend, and operate.

---

## 1. Language & Runtime: Go

**Decision:** Go with the standard library `net/http` package.

**Reasoning:**
- `net/http` is production-grade — no external frameworks or dependencies required
- Compiles to a single static binary — trivial to containerize and distribute
- Low memory footprint (~5–10 MB RSS) — cost-efficient, allows smaller instance types
- Fast startup time (<100ms) — critical for pod scaling and crash recovery
- Built-in concurrency model (goroutines) handles thousands of simultaneous connections
- First-class support in the Kubernetes ecosystem

**Alternatives considered:**
- *Python/Flask*: Higher memory usage, slower startup, requires runtime in the container image
- *Node.js*: Viable, but Go's static binary and lower resource usage are better suited for infrastructure services
- *Rust*: Excellent performance but higher development time for marginal gains on this workload

## 2. Container Strategy: Multi-Stage Build + Distroless

**Decision:** Multi-stage Docker build with `gcr.io/distroless/static-debian12` as the runtime base.

**Reasoning:**
- Build stage uses the full Go toolchain; the runtime image contains only the compiled binary
- Distroless has no shell, no package manager, no OS utilities — minimal attack surface
- Final image is ~7 MB compared to ~800 MB for a full Go development image
- No CVEs from OS packages to manage or patch
- ECR scan-on-push validates the image for known vulnerabilities on every push
- Runs as `nonroot` user — limits damage if the process is compromised

**Trade-off:** Debugging is harder without a shell. For production troubleshooting, a debug variant (`distroless/static-debian12:debug`) can be deployed temporarily to a specific pod.

## 3. Cloud Platform: AWS + EKS

**Decision:** Amazon Web Services with Elastic Kubernetes Service.

**Reasoning:**
- EKS provides a managed Kubernetes control plane with a 99.95% uptime SLA
- Managed node groups handle node provisioning, OS patching, and lifecycle automatically
- Native integration with ECR (container images), IAM (access control), and VPC (networking) reduces operational overhead
- IRSA (IAM Roles for Service Accounts) provides secure, credential-free access from pods to AWS services
- ALB Ingress Controller provisions a fully managed L7 load balancer with health checks and cross-AZ distribution

**Portability:** The application code and Helm chart are cloud-agnostic. Only the Terraform configuration and ingress annotations are AWS-specific. Migrating to another cloud provider requires replacing the Terraform layer and updating ingress annotations.

## 4. Infrastructure as Code: Terraform

**Decision:** Terraform for all cloud resource provisioning.

**Reasoning:**
- Industry standard for declarative infrastructure management
- The code *is* the documentation of the infrastructure state
- The AWS provider is well-maintained and feature-complete
- State file enables drift detection — identifies manual changes that diverge from the code
- Plan/apply workflow allows reviewing changes before they take effect

**PoC simplification:** Local state file. For production, use an S3 backend with DynamoDB state locking to enable team collaboration and prevent concurrent modifications:

```hcl
terraform {
  backend "s3" {
    bucket         = "trdl-terraform-state"
    key            = "terraform/state"
    region         = "eu-north-1"
    dynamodb_table = "trdl-terraform-lock"
    encrypt        = true
  }
}
```

## 5. Network Architecture

**Decision:** Custom VPC with public and private subnets across 3 availability zones.

**Reasoning:**
- **Private subnets** for EKS nodes — no direct internet exposure, reduced attack surface
- **Public subnets** for the ALB — the load balancer must be internet-facing to receive user traffic
- **NAT Gateway** allows nodes in private subnets to reach the internet outbound (pull container images, access AWS APIs) without being reachable inbound
- **3 AZs** provide the physical redundancy required for high availability
- Subnet tagging (`kubernetes.io/role/elb`, `kubernetes.io/role/internal-elb`) enables automatic subnet discovery by the AWS Load Balancer Controller

**Trade-off:** A single NAT Gateway is a potential single point of failure for outbound traffic. Existing pods continue serving during a NAT Gateway outage, but new pods cannot pull images. For production, deploy one NAT Gateway per AZ.

## 6. Kubernetes Architecture

Each Kubernetes resource serves a specific purpose in the HA design:

### Deployment (3 replicas with anti-affinity)
- **3 replicas** ensures one pod per availability zone
- **Pod anti-affinity** on `topology.kubernetes.io/zone` prevents multiple pods from landing in the same AZ — a single AZ failure cannot take down the service
- **Rolling update strategy** with `maxUnavailable: 0` and `maxSurge: 1` ensures zero-downtime deployments — a new pod must be healthy before an old one is terminated

### HorizontalPodAutoscaler (HPA)
- Scales between 3 and 10 replicas based on CPU utilization (70% target)
- Minimum of 3 guarantees AZ-level redundancy even during low traffic
- Maximum of 10 provides cost protection against runaway scaling
- Metrics server (included by default in EKS) provides the CPU measurements

### PodDisruptionBudget (PDB)
- `minAvailable: 2` prevents Kubernetes from voluntarily evicting pods below this threshold
- Protects availability during node upgrades, cluster maintenance, and scaling operations
- Works in conjunction with EKS managed node group rolling updates

### Service (NodePort) + Ingress (ALB)
- NodePort Service exposes pods on each node, enabling ALB target registration
- Ingress resource triggers the AWS Load Balancer Controller to provision an internet-facing ALB
- ALB performs health checks on `/healthz` and distributes traffic across all healthy pods in all AZs
- ALB provides cross-zone load balancing, connection draining, and access logging

### Liveness and Readiness Probes
- **Liveness probe** (`/healthz`, every 10s): detects hung or deadlocked processes and triggers a pod restart
- **Readiness probe** (`/readyz`, every 5s): prevents traffic from reaching pods that are starting up or temporarily unable to serve
- Separate endpoints allow independent health semantics — readiness can check downstream dependencies without affecting liveness

## 7. CI/CD Pipeline

**Decision:** GitLab CI with 5 stages and image tagging by Git SHA.

**Pipeline stages:**

| Stage | Purpose | Runs on |
|---|---|---|
| Lint | Code quality (`go vet`, `golangci-lint`) | Merge requests + main branch |
| Test | Unit tests with race detection and coverage | Merge requests + main branch |
| Build | Docker build + push to ECR | Main branch only |
| Deploy | `helm upgrade --install` to EKS | Main branch only |
| E2E | Smoke tests against live ALB endpoint | Main branch only |

**Design decisions:**
- Images tagged with Git SHA provide full traceability from any running container back to the exact source code
- ECR immutable tags prevent accidental image overwrites
- Build and deploy only run on the main branch — feature branches are validated but not deployed
- `--wait --timeout 120s` on Helm ensures the pipeline fails if pods don't become healthy

**PoC simplification:** Direct `helm upgrade` from CI. For production, use a GitOps operator (Flux or ArgoCD) that watches a Git repository for manifest changes, providing an audit trail and enabling easy rollback.

## 8. High Availability Analysis

| Mechanism | Failure Scenario | Protection |
|---|---|---|
| 3 replicas across 3 AZs | AZ failure, node failure | Service continues on remaining AZs |
| HPA | Traffic spike | Automatic scaling prevents overload |
| PDB | Node maintenance, cluster upgrade | Minimum pods always available |
| Rolling updates | Bad deployment | Old pods serve until new pods are verified healthy |
| Liveness probes | Process hang, deadlock | Automatic restart and recovery |
| Readiness probes | Slow startup, transient errors | No traffic to unhealthy pods |
| EKS managed control plane | Control plane failure | AWS SLA: 99.95%, spans 3 AZs |
| ALB | Load balancer failure | AWS-managed, multi-AZ, 99.99% SLA |
| Graceful shutdown | Pod termination during active requests | In-flight requests complete before exit |

The data plane (pods serving traffic) can exceed the control plane SLA because pods continue operating even during brief control plane unavailability.

## 9. Production Enhancements

The following items are out of scope for the PoC but would be required for a production deployment:

| Area | PoC | Production |
|---|---|---|
| Transport security | HTTP | HTTPS with ACM certificates on ALB |
| Terraform state | Local file | S3 + DynamoDB backend with locking and encryption |
| Deployment strategy | Rolling update from CI | GitOps with Flux/ArgoCD; canary deployments with Flagger |
| Observability | None | Prometheus + Grafana for metrics; CloudWatch or EFK for logs; PagerDuty for alerting |
| Service mesh | None | Istio or Linkerd for mTLS, traffic management, and observability |
| Multi-region | Single region (eu-north-1) | Multi-region with Route 53 failover routing |
| Network isolation | None | Kubernetes NetworkPolicies for pod-to-pod traffic control |
| NAT redundancy | Single NAT Gateway | One NAT Gateway per AZ |
| Secrets management | No secrets needed | External Secrets Operator + AWS Secrets Manager |
