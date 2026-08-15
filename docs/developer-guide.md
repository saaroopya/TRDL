# Developer Guide — Building, Deploying, and Extending TRDL

This guide provides everything a developer needs to set up the TRDL environment, deploy the service, and extend it while maintaining the high-availability guarantees of the platform.

---

## Architecture Overview

### System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         AWS (eu-north-1)                            │
│                                                                     │
│  ┌─── Public Subnets (ALB lives here, OUTSIDE the cluster) ─────┐  │
│  │                                                               │  │
│  │   ┌─────────────────────────────────────────────────────┐     │  │
│  │   │              ALB (Internet-Facing)                  │     │  │
│  │   │     trdl-xxx.eu-north-1.elb.amazonaws.com           │     │  │
│  │   └──────────┬──────────────┬──────────────┬────────────┘     │  │
│  │              │              │              │                   │  │
│  └──────────────┼──────────────┼──────────────┼──────────────────┘  │
│                 │              │              │                      │
│  ┌─── Private Subnets (EKS Cluster lives here) ─────────────────┐  │
│  │              │              │              │                   │  │
│  │      ┌───────▼──┐   ┌──────▼───┐   ┌─────▼────┐              │  │
│  │      │  AZ-a    │   │  AZ-b    │   │  AZ-c    │              │  │
│  │      │          │   │          │   │          │              │  │
│  │      │ ┌──────┐ │   │ ┌──────┐ │   │ ┌──────┐ │              │  │
│  │      │ │ Pod1 │ │   │ │ Pod2 │ │   │ │ Pod3 │ │              │  │
│  │      │ │ :8080│ │   │ │ :8080│ │   │ │ :8080│ │              │  │
│  │      │ └──────┘ │   │ └──────┘ │   │ └──────┘ │              │  │
│  │      │  Node1   │   │  Node2   │   │  Node3   │              │  │
│  │      │ (EC2)    │   │ (EC2)    │   │ (EC2)    │              │  │
│  │      └──────────┘   └──────────┘   └──────────┘              │  │
│  │                                                               │  │
│  │      EKS Cluster (trdl-cluster)                               │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

User Request ──► ALB (public subnet) ──► Pods (private subnet)
```

### Request Flow

```
User                ALB              K8s Service         Pod
  │                  │                   │                 │
  │  GET /           │                   │                 │
  │─────────────────►│                   │                 │
  │                  │  health check OK  │                 │
  │                  │──────────────────►│                 │
  │                  │                   │  forward to pod │
  │                  │                   │────────────────►│
  │                  │                   │                 │ rootHandler()
  │                  │                   │          "42\n" │
  │                  │                   │◄────────────────│
  │                  │◄──────────────────│                 │
  │  200 OK "42\n"   │                   │                 │
  │◄─────────────────│                   │                 │
```

### High Availability Mechanisms

```
┌─────────────────────────────────────────────────────────────────┐
│                     HA Protection Layers                         │
│                                                                  │
│  ┌─────────────┐  Pod crashes?                                   │
│  │  Liveness   │  ──► Kubernetes restarts it automatically       │
│  │  Probe      │                                                 │
│  └─────────────┘                                                 │
│                                                                  │
│  ┌─────────────┐  Pod not ready?                                 │
│  │  Readiness  │  ──► ALB stops sending traffic to it            │
│  │  Probe      │                                                 │
│  └─────────────┘                                                 │
│                                                                  │
│  ┌─────────────┐  AZ goes down?                                  │
│  │  Anti-      │  ──► Pods in other 2 AZs keep serving           │
│  │  Affinity   │                                                 │
│  └─────────────┘                                                 │
│                                                                  │
│  ┌─────────────┐  Traffic spike?                                 │
│  │  HPA        │  ──► Auto-scale from 3 to 10 pods               │
│  │             │                                                 │
│  └─────────────┘                                                 │
│                                                                  │
│  ┌─────────────┐  Node maintenance?                              │
│  │  PDB        │  ──► Always keep at least 2 pods running        │
│  │             │                                                 │
│  └─────────────┘                                                 │
│                                                                  │
│  ┌─────────────┐  New version deployed?                          │
│  │  Rolling    │  ──► New pods start before old pods stop        │
│  │  Update     │      (maxUnavailable: 0)                        │
│  └─────────────┘                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### CI/CD Pipeline

```
git push to main
     │
     ▼
┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐
│  LINT   │───►│  TEST   │───►│  BUILD  │───►│ DEPLOY  │───►│   E2E   │
│         │    │         │    │         │    │         │    │         │
│ go vet  │    │ go test │    │ docker  │    │ helm    │    │ curl    │
│ golangci│    │ -race   │    │ build   │    │ upgrade │    │ ALB     │
│         │    │         │    │ push ECR│    │ to EKS  │    │ verify  │
└─────────┘    └─────────┘    └─────────┘    └─────────┘    └─────────┘
     │              │              │              │              │
  code clean?    tests pass?   image built?   pods healthy?  service works?
     │              │              │              │              │
     ▼              ▼              ▼              ▼              ▼
   ❌ stop        ❌ stop       ❌ stop       ❌ stop        ❌ alert
```

### Infrastructure (Terraform)

```
terraform apply creates:
│
├── Networking
│   ├── VPC (10.0.0.0/16)
│   ├── 3 Private Subnets (pods + nodes)
│   ├── 3 Public Subnets (ALB)
│   ├── Internet Gateway (public internet access)
│   ├── NAT Gateway (outbound-only for private subnets)
│   └── Route Tables (traffic rules)
│
├── Container Registry
│   └── ECR Repository (Docker images)
│
├── Kubernetes
│   ├── EKS Cluster (control plane)
│   └── Node Group (3 × t3.small EC2 instances)
│
└── IAM (permissions)
    ├── Cluster Role (EKS management)
    ├── Node Role (join cluster + pull images + pod networking)
    └── LB Controller Role (create/manage ALBs via OIDC trust)
```

---

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Go | ≥ 1.22 | Application development and testing |
| Docker | ≥ 24.0 | Container image builds |
| Terraform | ≥ 1.7 | Infrastructure provisioning |
| Helm | ≥ 3.14 | Kubernetes application deployment |
| kubectl | ≥ 1.29 | Kubernetes cluster interaction |
| AWS CLI | ≥ 2.0 | AWS authentication, ECR access, EKS configuration |

---

## 1. Local Development

### Running the Application

```bash
cd app
go run main.go
```

The server starts on port 8080. Verify it:

```bash
curl http://localhost:8080/        # → 42
curl http://localhost:8080/healthz  # → ok
curl http://localhost:8080/readyz   # → ok
```

### Running Unit Tests

```bash
cd app
go test -v -race ./...
```

The `-race` flag enables Go's race detector, which identifies concurrency bugs. All tests should pass before committing.

### Building and Running the Container

```bash
cd app
docker build -t trdl:local .
docker run -p 8080:8080 trdl:local
curl http://localhost:8080/  # → 42
```

---

## 2. Infrastructure Setup

This section provisions the AWS environment. It only needs to be done once.

### 2.1 Configure AWS Credentials

```bash
aws configure
# Enter: Access Key ID, Secret Access Key, region (eu-north-1)
```

### 2.2 Provision the EKS Cluster

```bash
cd terraform

terraform init     # Download provider plugins
terraform plan     # Preview what will be created
terraform apply    # Create the infrastructure (~15 minutes)
```

This creates: VPC with public/private subnets across 3 AZs, EKS cluster, managed node group (3 nodes), ECR repository, and IAM roles.

### 2.3 Install the AWS Load Balancer Controller

The ALB Ingress requires the AWS Load Balancer Controller running in the cluster:

```bash
# Connect to the cluster
aws eks update-kubeconfig \
  --name $(terraform output -raw cluster_name) \
  --region $(terraform output -raw region)

# Verify connectivity
kubectl get nodes    # Should show 3 nodes across 3 AZs

# Install the controller
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$(terraform output -raw cluster_name) \
  --set serviceAccount.create=true \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform output -raw lb_controller_role_arn)
```

---

## 3. Deploying TRDL

### 3.1 Push the Container Image to ECR

```bash
# Authenticate Docker with ECR
aws ecr get-login-password --region $(terraform output -raw region) | \
  docker login --username AWS --password-stdin $(terraform output -raw ecr_repository_url)

# Tag and push
docker tag trdl:local $(terraform output -raw ecr_repository_url):$(git rev-parse --short HEAD)
docker push $(terraform output -raw ecr_repository_url):$(git rev-parse --short HEAD)
```

### 3.2 Deploy with Helm

```bash
helm upgrade --install trdl k8s/trdl/ \
  --set image.repository=$(terraform output -raw ecr_repository_url) \
  --set image.tag=$(git rev-parse --short HEAD)
```

### 3.3 Verify the Deployment

```bash
# Check pods are running (expect 3, one per AZ)
kubectl get pods -l app=trdl -o wide

# Check the service
kubectl get svc trdl

# Get the ALB DNS name (may take 2-3 minutes to provision)
kubectl get ingress trdl

# Test the live service
ALB_DNS=$(kubectl get ingress trdl -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://${ALB_DNS}/    # → 42

# Run the full E2E test suite
TRDL_URL="http://${ALB_DNS}" bash tests/e2e_test.sh
```

---

## 4. CI/CD Pipeline

The GitLab CI pipeline automates the entire workflow on every push to `main`:

| Stage | Action | Failure means |
|---|---|---|
| Lint | `go vet` + `golangci-lint` | Code quality issues — fix before merging |
| Test | `go test -race` with coverage | Logic bugs — fix the code |
| Build | Docker build + push to ECR | Dockerfile or compilation error |
| Deploy | `helm upgrade` to EKS | Chart error or pods not becoming healthy |
| E2E | Smoke tests against live ALB | Service not responding correctly after deploy |

### Required CI/CD Variables

Configure these in GitLab → Settings → CI/CD → Variables:

| Variable | Example | Purpose |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | `AKIA...` | AWS authentication |
| `AWS_SECRET_ACCESS_KEY` | `wJal...` | AWS authentication |
| `AWS_REGION` | `eu-north-1` | Target region |
| `ECR_REGISTRY` | `123456789.dkr.ecr.eu-north-1.amazonaws.com` | Container registry |
| `EKS_CLUSTER` | `trdl-cluster` | Target cluster name |
| `TRDL_ALB_DNS` | `trdl-abc123.eu-north-1.elb.amazonaws.com` | ALB endpoint for E2E tests |

---

## 5. Requirements for Extending TRDL

When adding features to TRDL, the following requirements must be satisfied to maintain the high-availability guarantees of the Kubernetes environment.

### 5.1 Health Endpoints — Mandatory

The application must expose two health endpoints:

| Endpoint | Purpose | Kubernetes Usage |
|---|---|---|
| `GET /healthz` | Liveness — is the process alive and responsive? | Failure triggers pod restart |
| `GET /readyz` | Readiness — can the process accept traffic? | Failure removes pod from load balancer |

These endpoints are already implemented. **Do not remove them.**

If your extension adds external dependencies (database, cache, external API), update the readiness handler to verify those connections:

```go
func readyzHandler(w http.ResponseWriter, r *http.Request) {
    if err := db.Ping(); err != nil {
        w.WriteHeader(http.StatusServiceUnavailable)
        return
    }
    w.WriteHeader(http.StatusOK)
}
```

The liveness handler should remain simple — it checks whether the process itself is responsive, not whether dependencies are available. A failed dependency should make the pod *unready* (stop receiving traffic), not trigger a restart.

### 5.2 Graceful Shutdown — Mandatory

The application must handle `SIGTERM` and complete in-flight requests before exiting. Kubernetes sends `SIGTERM` during:
- Rolling updates (deploying a new version)
- Scale-down events (HPA reducing replicas)
- Node drains (maintenance, upgrades)

The current implementation handles this with a 15-second shutdown timeout. **Do not remove the signal handling code in `main.go`.**

If your extension adds background workers or long-running connections, ensure they are also drained during shutdown:

```go
<-done  // SIGTERM received
// Stop accepting new work
worker.Stop()
// Wait for in-progress work to complete
worker.Wait()
// Then shut down the HTTP server
srv.Shutdown(ctx)
```

### 5.3 Resource Limits — Mandatory

CPU and memory requests/limits are defined in `values.yaml`. The HPA uses CPU requests as the scaling baseline.

If your extension increases resource consumption, update the values accordingly:

```yaml
resources:
  requests:
    cpu: 50m       # increase if your code is CPU-intensive
    memory: 32Mi   # increase if your code uses more memory
  limits:
    cpu: 200m      # upper bound — pod is throttled beyond this
    memory: 64Mi   # upper bound — pod is killed (OOMKill) beyond this
```

**Important:** Set memory limits with headroom. If your application occasionally spikes to 60Mi, set the limit to at least 80Mi. An OOMKill restarts the pod and drops in-flight requests.

### 5.4 Statelessness — Strongly Recommended

The HA architecture assumes pods are interchangeable. Any pod can handle any request. If your extension requires state:

- Use an external store (RDS, ElastiCache, S3) — not local disk
- Ensure any pod can handle any request without depending on a previous request
- Avoid session affinity — it breaks even load distribution and reduces the effectiveness of autoscaling

Local disk storage is lost when a pod restarts, which can happen at any time due to scaling, maintenance, or failure recovery.

### 5.5 Structured Logging — Recommended

Log in JSON format to stdout. This integrates automatically with CloudWatch Container Insights or any log aggregation pipeline (Fluentd, Fluent Bit):

```go
log.Printf(`{"level":"info","msg":"request served","path":"%s","status":%d,"duration_ms":%d}`,
    r.URL.Path, status, elapsed.Milliseconds())
```

Avoid logging to files — container stdout/stderr is the standard log channel in Kubernetes. File-based logs are lost when pods restart and are not collected by log aggregation tools.

### 5.6 Configuration via Environment Variables — Recommended

Use environment variables for any value that differs between environments (port, log level, feature flags, external service URLs). Never hardcode these values.

The current implementation reads `PORT` from the environment with a sensible default:

```go
port := os.Getenv("PORT")
if port == "" {
    port = "8080"
}
```

To add new configuration, define the variable in the Helm chart's `deployment.yaml`:

```yaml
env:
  - name: DATABASE_URL
    value: "{{ .Values.databaseUrl }}"
```

And add the default value to `values.yaml`:

```yaml
databaseUrl: "postgres://localhost:5432/trdl"
```

This allows each environment (dev, staging, production) to use different values without code changes.

---

## 6. Teardown

Remove resources in this order to avoid orphaned AWS resources:

```bash
# 1. Remove Kubernetes resources (this deletes the ALB)
helm uninstall trdl

# 2. Remove the LB controller
helm uninstall aws-load-balancer-controller -n kube-system

# 3. Destroy the infrastructure
cd terraform
terraform destroy
```

**Important:** Always uninstall Helm releases before running `terraform destroy`. The ALB created by the Ingress is an AWS resource managed by the LB controller, not by Terraform. If Terraform deletes the VPC while the ALB still exists, the deletion will fail due to lingering network interfaces.

---

## 7. Troubleshooting

| Symptom | Likely Cause | Resolution |
|---|---|---|
| Pods in `CrashLoopBackOff` | Application crashing on startup | `kubectl logs <pod-name>` — check for startup errors |
| Pods in `ImagePullBackOff` | Wrong ECR URL or missing permissions | Verify the image URL matches `terraform output ecr_repository_url` and the node role has `AmazonEC2ContainerRegistryReadOnly` |
| Ingress has no address | ALB still provisioning, or LB controller not running | Wait 2-3 minutes. Check controller: `kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller` |
| ALB returns 502 | Pods not ready, or security group blocking traffic | Check pod readiness: `kubectl get pods`. Check events: `kubectl describe ingress trdl` |
| ALB returns 503 | No healthy targets | Verify pods are running and `/healthz` returns 200 |
| HPA not scaling | Metrics server unavailable | `kubectl top pods` — if this fails, metrics server needs attention |
| `terraform apply` fails | Service quotas or APIs not enabled | Check error message. Common fix: `aws service-quotas` or enable EKS API in the region |
| `helm upgrade` hangs | Pods not becoming ready within timeout | `kubectl describe pod <pod-name>` — check events for scheduling or image pull issues |
