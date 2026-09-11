# Contributing to SmartScale AI

Welcome! This guide covers everything needed to set up the development
environment, run tests, and submit a pull request.

---

## 1. Local Development Setup

### Prerequisites

```bash
# Required tools
git --version           # >= 2.40
python --version        # >= 3.10
docker --version        # >= 24.0
terraform version       # >= 1.6
kubectl version --short # >= 1.28
helm version            # >= 3.12
aws --version           # AWS CLI >= 2.13

# Optional (for full cluster workflow)
# EKS cluster configured in ~/.kube/config
```

### Clone and Install

```bash
git clone https://github.com/Harshads-git/aws-keda-eks-autoscaling.git
cd aws-keda-eks-autoscaling

# Install Python app dependencies
pip install -r application/requirements.txt
pip install -r application/requirements-dev.txt

# Install AI module dependencies
pip install -r ai/requirements.txt

# Install pre-commit hooks (runs automatically on every commit)
pip install pre-commit
pre-commit install
```

---

## 2. Running Tests

### Unit Tests (No AWS account needed)

```bash
# Application tests (moto mocks all SQS calls)
cd application
pytest test_app.py -v --cov=app --cov-report=term-missing

# Chaos / resilience tests
pytest chaos_test.py -v

# AI predictor tests
cd ../ai
pytest test_predictor.py -v

# Run everything at once
cd ..
pytest application/test_app.py application/chaos_test.py ai/test_predictor.py -v
```

### Helm Lint

```bash
helm lint ./helm/keda-demo \
  --set image.repository=test/app \
  --set aws.sqsQueueUrl=https://sqs.us-east-1.amazonaws.com/123/q \
  --set aws.irsaRoleArn=arn:aws:iam::123:role/role
```

### Terraform Validate

```bash
cd terraform
terraform fmt -check -recursive     # Check formatting
terraform init -backend=false       # Init without S3 backend
terraform validate                  # Validate all modules
```

### Chaos Test (requires running cluster)

```bash
export QUEUE_URL=$(terraform output -raw sqs_queue_url)
bash scripts/chaos-test.sh --dry-run        # Safe: no cluster changes
bash scripts/chaos-test.sh --experiment pod-kill  # Live test
```

---

## 3. Project Structure

```
aws-keda-eks-autoscaling/
├── application/          # Python SQS consumer + tests
│   ├── app.py            # Main consumer (edit for business logic changes)
│   ├── test_app.py       # Unit tests (moto)
│   └── chaos_test.py     # Resilience tests
├── ai/                   # Predictive scaling AI prototype
│   ├── predictor.py      # LinearRegression queue depth predictor
│   └── keda_external_scaler_stub.py
├── manifests/            # Raw Kubernetes YAML (used without Helm)
├── helm/keda-demo/       # Helm chart (parametrized manifests)
├── terraform/            # All AWS infrastructure as code
│   └── modules/          # vpc, eks, sqs, irsa, monitoring
├── scripts/              # Setup, deploy, test, and chaos scripts
├── docs/                 # 11 guides (helm, security, observability, etc.)
└── .github/              # CI/CD workflows + PR/issue templates
```

---

## 4. Making Changes

### Commit Convention (strictly enforced by CI)

All commits and PR titles must follow **Conventional Commits**:

```
<type>(<scope>): <short description>

Types:  feat | fix | docs | test | ci | chore | refactor | perf
Scope:  optional, e.g. sqs | keda | terraform | helm | ai | ci

Examples:
  feat(keda): increase maxReplicaCount to 10
  fix(app): handle empty SQS message body without crashing
  docs(security): add RBAC verification commands
  test(ai): add predictor accuracy regression test
  ci: add Python 3.12 to matrix
```

### Branch Naming

```
feat/short-description       # New features
fix/issue-123-description    # Bug fixes referencing issue number
docs/section-name            # Documentation only
chore/dependency-update      # Maintenance
```

### PR Checklist (auto-loaded from PR template)

Before opening a PR, ensure:
- `pytest` passes locally on all changed modules
- `helm lint` passes if Helm chart was modified
- `terraform validate` passes if `.tf` files were modified
- No hardcoded AWS account IDs, secrets, or passwords
- Commit messages explain the WHY, not just the WHAT

---

## 5. Key Architecture Rules

These rules protect the system's correctness — don't bypass them:

| Rule | Why |
|---|---|
| Never add `spec.replicas` to the Deployment | KEDA manages replicas via HPA — setting it causes conflicts |
| Always call `delete_message()` only on success | On failure: let visibility timeout redeliver (at-least-once guarantee) |
| `terminationGracePeriodSeconds` must be > `WaitTimeSeconds` | Pod must outlive the longest possible SQS long-poll (20s) |
| IRSA annotation goes on the ServiceAccount, not the Pod | Changing pod annotations doesn't rotate credentials |
| `resourceNames` on RBAC Rules scopes access to one ConfigMap | Without it, the SA can read any ConfigMap in the namespace |

---

## 6. Adding a New Feature

### Adding a new Kubernetes resource

1. Add the raw YAML to `manifests/` with inline comments explaining the WHY
2. Add the Helm template to `helm/keda-demo/templates/` with `{{- if .Values.feature.enabled }}`
3. Add the feature flag to `helm/keda-demo/values.yaml` with a clear comment
4. Update `scripts/deploy-all-manifests.sh` with the new step (numbered)
5. Document in the relevant `docs/` guide

### Adding a new Terraform resource

1. Add to the appropriate module in `terraform/modules/<module>/`
2. Add outputs if other modules need to reference the resource
3. Run `terraform fmt -recursive && terraform validate`
4. Update `docs/terraform-guide.md` if the workflow changes

### Adding a new test

1. Unit tests → `application/test_app.py` or `application/chaos_test.py`
2. AI tests → `ai/test_predictor.py`
3. All tests must use `moto` for AWS mocking (no real AWS account in CI)
4. Aim for coverage increase, not decrease (`--cov-fail-under=80`)
