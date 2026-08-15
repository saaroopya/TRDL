# TRDL — The Responding Dark Laughter

A high-availability web service that returns the value `42`.

```
$ curl http://<ALB_DNS>/
42
```

## Project Structure

```
.
├── app/                    # Application code
│   ├── main.go             # HTTP server
│   ├── main_test.go        # Unit tests
│   ├── Dockerfile          # Container image
│   └── .dockerignore
├── terraform/              # Infrastructure as Code (EKS on AWS)
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── lb-controller-policy.json
│   └── terraform.tfvars.example
├── k8s/                    # Kubernetes manifests (Helm chart)
│   └── trdl/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── hpa.yaml
│           ├── pdb.yaml
│           └── ingress.yaml
├── .gitlab-ci.yml          # CI/CD pipeline
├── docs/
│   ├── discovery.md        # Discovery & planning document
│   ├── architecture.md     # Architecture decisions & reasoning
│   └── developer-guide.md  # Guide for developers extending TRDL
└── tests/
    └── e2e_test.sh         # End-to-end smoke tests
```

## Quick Start

See [docs/developer-guide.md](docs/developer-guide.md) for full instructions.

### Local Development

```bash
cd app
go run main.go
curl http://localhost:8080/
```

### Deploy to AWS/EKS

```bash
# 1. Provision infrastructure
cd terraform
terraform init && terraform apply

# 2. Install AWS Load Balancer Controller
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=trdl-cluster \
  --set serviceAccount.create=true \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform output -raw lb_controller_role_arn)

# 3. Deploy application
helm upgrade --install trdl k8s/trdl/
```

## Documentation

| Document | Purpose |
|---|---|
| [Discovery & Plan](docs/discovery.md) | Task breakdown, time estimates, assumptions |
| [Architecture](docs/architecture.md) | Technical decisions and reasoning |
| [Developer Guide](docs/developer-guide.md) | How to extend, build, and deploy TRDL |
