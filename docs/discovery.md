# Discovery & Planning Document

## 1. Problem Statement

Deploy **TRDL** — a web service returning `42` — as a proof-of-concept for a high-availability production system with strict SLA requirements (several "9"s uptime). The PoC must demonstrate that the architecture *can* meet those requirements, even though it won't run in production itself.

## 2. Approach

The system will be built in layers, each independently testable:

1. **Application** — A minimal HTTP server with health endpoints, packaged as a secure container image
2. **Infrastructure** — A Kubernetes cluster on AWS provisioned entirely through code (Terraform)
3. **Deployment** — A Helm chart that deploys the application with HA guarantees (multi-AZ, autoscaling, disruption budgets)
4. **Automation** — A CI/CD pipeline that lints, tests, builds, deploys, and verifies on every code push
5. **Documentation** — Architecture reasoning, developer guide, and this planning document

## 3. Assumptions

| # | Assumption | Rationale |
|---|---|---|
| A1 | AWS is the target cloud provider | Widely adopted; EKS is a mature managed Kubernetes offering |
| A2 | A single EKS cluster across 3 AZs is sufficient for the PoC | Multi-region adds cost and complexity beyond PoC scope; 3 AZs already provides strong HA |
| A3 | HTTP (not HTTPS) is acceptable for the PoC | TLS termination is a production concern; the PoC focuses on availability architecture |
| A4 | No persistent state is required | TRDL is stateless — it returns a constant. This simplifies HA design significantly |
| A5 | GitLab CI is the CI/CD platform | Industry standard, matches the tooling referenced in the role description |
| A6 | Container registry is AWS ECR | Native EKS integration; node IAM roles grant pull access without extra credentials |
| A7 | Budget is minimal — use small instance types | PoC cost optimization; architecture is the same regardless of instance size |

## 4. Task Breakdown & Time Estimates

| # | Task | Estimated Time | Notes |
|---|---|---|---|
| T1 | Discovery & planning (this document) | 2h | Define scope, assumptions, risks |
| T2 | Application code (Go HTTP server + unit tests) | 1.5h | Includes health endpoints, graceful shutdown, edge case handling |
| T3 | Dockerfile & container build | 0.5h | Multi-stage build, distroless base |
| T4 | Terraform — VPC, EKS cluster, ECR, IAM | 4h | Most complex task; networking, IAM roles, OIDC provider for LB controller |
| T5 | Kubernetes manifests (Helm chart) | 3h | Deployment, Service, Ingress, HPA, PDB with HA configuration |
| T6 | CI/CD pipeline (GitLab CI) | 2h | 5-stage pipeline: lint → test → build → deploy → e2e |
| T7 | End-to-end smoke tests | 1h | Bash script verifying live service through ALB |
| T8 | Architecture documentation | 2h | Technical decisions with reasoning for each choice |
| T9 | Developer guide | 2h | Setup instructions, extension requirements, troubleshooting |
| T10 | Review, polish, edge cases | 1.5h | Final pass on code quality, documentation clarity, and completeness |
| | **Total** | **~19.5h** | |

This fits within the 20-hour budget with a small margin for unexpected issues.

## 5. Deliverables

| Deliverable | Format | Purpose |
|---|---|---|
| Working HTTP server | Go source + Dockerfile | The application itself |
| Unit tests | Go test file | Verify application logic |
| E2E smoke tests | Bash script | Verify live system end-to-end |
| Infrastructure code | Terraform (.tf files) | Reproducible AWS environment |
| Deployment manifests | Helm chart | Reproducible Kubernetes deployment |
| CI/CD pipeline | .gitlab-ci.yml | Automated build and deployment |
| Architecture document | Markdown | Technical decisions and reasoning |
| Developer guide | Markdown | How to build, deploy, and extend TRDL |
| This discovery document | Markdown | Planning, scope, and estimates |

## 6. Scope

| In Scope (PoC) | Out of Scope (Production Enhancement) |
|---|---|
| Regional HA across 3 AZs | Multi-region with global load balancing |
| HPA (auto-scaling) + PDB (disruption budget) | Advanced autoscaling |
| Liveness and readiness probes | Full observability stack (Prometheus, Grafana, alerting) |
| CI/CD pipeline with quality gates | Canary deployments |
| HTTP | HTTPS with certificate management |
| Helm chart | Service mesh for pod to  pod communication |
| Unit tests + E2E smoke tests | Load testing, chaos engineering(servive failures) |


## 7. Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| AWS service limits on new accounts | Cannot provision EKS cluster or nodes | Medium | Use small instances (t3.small); request limit increase if needed |
| Terraform state loss | Cannot manage or destroy infrastructure | Low | PoC uses local state; document S3 backend for production |
| Container image vulnerabilities | Security exposure in running containers | Low | Distroless base image minimizes attack surface; ECR scan-on-push enabled |
| Single-region cluster failure | Total service outage | Very Low | Regional cluster spans 3 AZs; multi-region documented as production enhancement |
| NAT Gateway single point of failure | New pods cannot pull images | Low | Existing pods continue serving; document multi-AZ NAT for production |

## 8. Success Criteria

The PoC is complete when:

1. `curl http://<ALB_DNS>/` returns `42` with HTTP 200
2. The service runs across 3 availability zones with automatic failover
3. A code push to `main` triggers automated lint → test → build → deploy → verify
4. All unit tests and E2E smoke tests pass
5. Documentation enables a developer to deploy the system and understand how to extend it
6. Architecture decisions are documented with clear reasoning
