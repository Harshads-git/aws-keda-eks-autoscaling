# CI/CD Guide: GitHub Actions for KEDA Demo

This guide explains the CI/CD architecture, how to configure GitHub Secrets,
and how GitHub OIDC eliminates the need for static AWS credentials.

---

## 1. Workflow Architecture

```
Developer pushes to feature branch
          │
          ▼
    Opens Pull Request
          │
          ▼
    CI Workflow (ci.yml) runs:
    ├── lint     → pre-commit hooks + conventional commit check
    ├── test     → pytest (moto mock, no real AWS)
    ├── docker-build → validate Dockerfile (no push)
    └── terraform-validate → fmt check + validate
          │
          ├── Any job fails → PR blocked (cannot merge)
          │
          ▼
    All jobs pass → PR approved and merged to main
          │
          ▼
    CD Workflow (cd.yml) runs:
    ├── build-and-push → ECR image (sha-xxxxxxxx tag)
    └── deploy → kubectl apply to EKS cluster
```

---

## 2. GitHub OIDC — No Static AWS Keys

Traditional approach (⛔ what NOT to do):
```
GitHub Secret: AWS_ACCESS_KEY_ID=AKIAXXXXXXXXXXXXXXXX
GitHub Secret: AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI...
```
**Problems:** Keys never expire. Key leakage = full AWS account compromise.
Rotation requires updating multiple secrets manually.

This project uses **GitHub OIDC federation** instead:

```
GitHub Actions runtime
  └── generates short-lived JWT (15-minute validity)
        └── presented to AWS STS
              └── STS validates JWT against GitHub OIDC provider
                    └── STS checks IAM role trust policy:
                          Condition:
                            sub == repo:Harshads-git/aws-keda-eks-autoscaling:ref:refs/heads/main
                          └── Returns 15-minute temporary credentials
```

**Benefits:**
- No long-lived credentials anywhere
- Credentials auto-expire after 15 minutes
- Trust policy restricts to your specific repo + branch
- CloudTrail shows `GitHubActions-<run-id>` as the actor

---

## 3. Required GitHub Secrets

Go to: **Repository → Settings → Secrets and variables → Actions → New repository secret**

| Secret Name | Value | How to Get |
|---|---|---|
| `AWS_ACCOUNT_ID` | `183264980` | `aws sts get-caller-identity --query Account --output text` |
| `AWS_REGION` | `us-east-1` | Your Terraform region |
| `EKS_CLUSTER_NAME` | `keda-demo-dev-cluster` | `terraform output -raw cluster_name` |
| `SQS_QUEUE_URL` | `https://sqs.us-east-1...` | `terraform output -raw sqs_queue_url` |

> ⚠️ Do NOT add `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` — OIDC replaces them.

---

## 4. Setting Up the GitHub Actions IAM Role

Before the CD workflow can run, you must create the IAM role for GitHub Actions.
This is done in **Day 14** via `scripts/setup-github-oidc.sh`. Here's what it creates:

### IAM OIDC Provider (one-time per AWS account)
```json
{
  "Url": "https://token.actions.githubusercontent.com",
  "ClientIDList": ["sts.amazonaws.com"],
  "ThumbprintList": ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}
```

### IAM Role Trust Policy
```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::183264980:oidc-provider/token.actions.githubusercontent.com"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringLike": {
      "token.actions.githubusercontent.com:sub":
        "repo:Harshads-git/aws-keda-eks-autoscaling:ref:refs/heads/main"
    },
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
    }
  }
}
```

### IAM Role Permissions
The GitHub Actions role needs:
- `ecr:GetAuthorizationToken`
- `ecr:BatchGetImage`, `ecr:PutImage` (on ECR repo)
- `eks:DescribeCluster` (to configure kubectl)
- `eks:UpdateNodegroupConfig` (for deployments)

---

## 5. CI Workflow: What Each Job Validates

### Job 1: lint
```bash
# What runs locally (equivalent):
pre-commit run --all-files

# PR title validation regex:
^(feat|fix|docs|chore|test|refactor|perf|style|ci|build|revert)(\(.+\))?: .{1,80}
```

**Common failures:**
- `black` reformats a file → commit the black-formatted version
- PR title "updated stuff" → rename to "fix: handle empty SQS response"
- Trailing whitespace → `pre-commit run trailing-whitespace`

### Job 2: test (moto SQS mock)
```bash
# What runs locally:
cd application
python -m pytest test_app.py -v --cov=app --cov-fail-under=80
```

Coverage threshold is **80%**. If adding a new function without tests, CI fails.

### Job 3: docker-build
```bash
# What runs locally:
docker build -t keda-demo-app:local ./application
```

**Common failures:**
- `COPY` references a file that doesn't exist → check path
- `pip install` fails → pin dependency version in requirements.txt

### Job 4: terraform-validate
```bash
# What runs locally:
cd terraform
terraform fmt -check -recursive   # Check (fails) or:
terraform fmt -recursive          # Fix (rewrites files)
terraform init -backend=false
terraform validate
```

---

## 6. CD Workflow: Deployment Pipeline

### Deployment Trigger
```bash
# CD runs automatically on merge to main:
git checkout main && git pull

# Or trigger manually (useful for rollbacks):
# GitHub UI → Actions → CD workflow → Run workflow → choose image_tag
```

### Image Tag Strategy
```
sha-a1b2c3d4  ← 8-char short SHA (default, production-grade)
latest        ← always points to most recent build (for quick manual deploys)
```

Find which commit is deployed:
```bash
kubectl get deploy keda-demo -n keda-demo \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# → 183264980.dkr.ecr.us-east-1.amazonaws.com/keda-demo-app:sha-a1b2c3d4

# Find commit:
git log --oneline | grep a1b2c3d4
```

### Rolling Deployment
```
Old pods:    [pod-v1] [pod-v1] [pod-v1]
Deploying:   [pod-v2] (new) → [pod-v1] × 2 (still running)
             [pod-v2] (new) → [pod-v2] (new) → [pod-v1] × 1 (still running)
Complete:    [pod-v2] [pod-v2] [pod-v2]
```
`kubectl rollout status --timeout=300s` ensures CD doesn't succeed before pods are healthy.

### Rollback
```bash
# Option 1: Deploy previous commit via workflow_dispatch
# GitHub UI → Actions → CD → Run workflow → image_tag: sha-<previous-sha>

# Option 2: kubectl rollout undo (immediate, no CD)
kubectl rollout undo deployment/keda-demo -n keda-demo
```

---

## 7. GitHub Environment Protection (Optional)

For production deployments, add a required reviewer to the `dev` environment:

1. Go to: **Repository → Settings → Environments → dev**
2. Enable **Required reviewers** → add yourself or your team
3. Now the CD deploy job pauses for approval before running

This creates a manual gate between build and deploy — useful if you want
to review what's being deployed before it goes live.

---

## References
- [GitHub OIDC with AWS](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [aws-actions/configure-aws-credentials](https://github.com/aws-actions/configure-aws-credentials)
- [GitHub Environments](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)
