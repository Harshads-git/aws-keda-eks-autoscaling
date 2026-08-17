# Amazon ECR Guide: Container Registry for the KEDA Demo

This guide covers everything you need to know about Amazon ECR (Elastic
Container Registry) as used in this project: authentication, lifecycle
policies, image tagging strategy, and how it integrates with EKS and CI/CD.

---

## 1. What is ECR and Why Use It?

Amazon ECR is a fully managed Docker container registry. In this project it
replaces **Google Artifact Registry / GCR** used in the reference repo.

```
Reference Repo (GCP)                    This Project (AWS)
────────────────────                    ─────────────────
Google Artifact Registry / GCR          Amazon ECR
gcr.io/<project>/<image>:tag            <account>.dkr.ecr.<region>.amazonaws.com/<repo>:tag
gcloud auth configure-docker            aws ecr get-login-password | docker login
```

**Why ECR over Docker Hub for EKS deployments:**

| Factor | Docker Hub | Amazon ECR |
|---|---|---|
| **Auth** | Docker credentials | AWS IAM — same auth as everything else |
| **Network** | Public internet | Private, same AWS network as EKS (fast!) |
| **Cost** | Rate limiting on free tier | Free Tier: 500MB/month |
| **Security** | Manual scanning | Built-in image scanning (Clair) on push |
| **Pull speed** | Variable (internet) | ~10x faster from EKS (same region) |
| **IAM integration** | None | EKS nodes auto-auth via IAM instance profile |

---

## 2. ECR Authentication Flow

ECR uses short-lived tokens (12-hour expiry), not permanent credentials.

```
                    ┌──────────────────────────────────────────────┐
                    │              Authentication Flow              │
                    └──────────────────────────────────────────────┘

Developer / CI Runner
        │
        │  1. aws ecr get-login-password --region us-east-1
        │     (calls STS using your IAM credentials)
        │
        ▼
    AWS IAM / STS
        │
        │  2. Returns a 12-hour Docker auth token (base64 encoded)
        │
        ▼
Docker CLI
        │
        │  3. docker login --username AWS --password <token> \
        │          <account>.dkr.ecr.<region>.amazonaws.com
        │
        ▼
    ECR Registry  ← Docker is now authenticated
        │
        │  4. docker push / docker pull work normally
        │
        ▼
    ECR Repository (keda-demo-app)
```

**The one-liner to authenticate Docker with ECR:**
```bash
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin \
    $(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com
```

**On EKS worker nodes:** No manual auth needed. The EC2 instance profile
attached to EKS nodes automatically grants ECR pull access. EKS manages this
transparently — pods can pull images from ECR in the same account without any
`imagePullSecrets`.

---

## 3. Image Tagging Strategy

This project uses a **dual-tag strategy** — every image gets two tags pushed simultaneously:

### Tag 1: Git SHA (Immutable, Traceable)

```bash
GIT_SHA=$(git rev-parse --short HEAD)
docker tag keda-demo-app:local ${ECR_REPO_URI}:sha-${GIT_SHA}
```

**Why SHA tags?**
- Exact traceability: you know which commit produced which running pod
- Rollback: `kubectl set image deployment/keda-demo app=${ECR_REPO_URI}:sha-abc1234`
- Immutable: SHA never changes, so `sha-abc1234` always means the same image

### Tag 2: `latest` (Mutable, Convenient)

```bash
docker tag keda-demo-app:local ${ECR_REPO_URI}:latest
```

**Why latest?**
- Local development: `docker pull ${ECR_REPO_URI}:latest` gets the newest image
- Initial deployments during development
- **Never use `latest` in production Kubernetes** — it bypasses change tracking

### Full build-tag-push sequence (automated in CI on Day 22):

```bash
GIT_SHA=$(git rev-parse --short HEAD)

# Build
docker build -t keda-demo-app:local ./application

# Tag both
docker tag keda-demo-app:local ${ECR_REPO_URI}:sha-${GIT_SHA}
docker tag keda-demo-app:local ${ECR_REPO_URI}:latest

# Push both
docker push ${ECR_REPO_URI}:sha-${GIT_SHA}
docker push ${ECR_REPO_URI}:latest

# Update Kubernetes deployment to new SHA
kubectl set image deployment/keda-demo \
  app=${ECR_REPO_URI}:sha-${GIT_SHA} \
  -n keda-demo
```

---

## 4. Lifecycle Policy: Controlling Storage Costs

Without a lifecycle policy, every `docker push` accumulates in ECR forever.
At 500 MB Free Tier, this fills up quickly during active development.

### This project's lifecycle policy (applied by `scripts/setup-ecr.sh`):

```json
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Keep last 10 tagged images",
      "selection": {
        "tagStatus": "tagged",
        "tagPrefixList": ["v", "sha-", "latest"],
        "countType": "imageCountMoreThan",
        "countNumber": 10
      },
      "action": { "type": "expire" }
    },
    {
      "rulePriority": 2,
      "description": "Delete untagged images after 1 day",
      "selection": {
        "tagStatus": "untagged",
        "countType": "sinceImagePushed",
        "countUnit": "days",
        "countNumber": 1
      },
      "action": { "type": "expire" }
    }
  ]
}
```

**Rule 1 explained:** Once you have 11+ tagged images, the oldest one
matching `v*`, `sha-*`, or `latest` is deleted. You always have the 10
most recent builds available.

**Rule 2 explained:** Untagged images are the leftover intermediate layers
from `docker build`. They appear when you push a new `latest` — the old
image that `latest` pointed to becomes untagged. This rule cleans them
up after 1 day.

---

## 5. Image Scanning

ECR integrates with **Amazon Inspector / Clair** to scan images for known
CVEs (Common Vulnerabilities and Exposures) at push time.

**Scanning is enabled in this project via `setup-ecr.sh`:**
```bash
--image-scanning-configuration scanOnPush=true
```

**How to view scan results:**
```bash
aws ecr describe-image-scan-findings \
  --repository-name keda-demo-app \
  --image-id imageTag=latest \
  --region us-east-1
```

**In CI (Day 25):** Trivy scans the image BEFORE it's pushed to ECR, acting
as a build gate. If HIGH or CRITICAL CVEs are found, the pipeline fails.
This is defense-in-depth: Trivy (pre-push) + ECR scanning (post-push).

---

## 6. ECR Repository URI Structure

```
<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<REPO_NAME>:<TAG>

Example:
123456789012.dkr.ecr.us-east-1.amazonaws.com/keda-demo-app:sha-a1b2c3d

Breakdown:
├── 123456789012          → Your 12-digit AWS account ID
├── dkr.ecr              → ECR's Docker registry endpoint
├── us-east-1            → AWS region (must match your EKS cluster region)
├── amazonaws.com        → AWS domain
├── keda-demo-app        → Repository name
└── sha-a1b2c3d          → Image tag (git SHA)
```

---

## 7. Useful ECR Commands Reference

```bash
# List all images in the repo
aws ecr list-images \
  --repository-name keda-demo-app \
  --region us-east-1

# Describe images (includes push date, size, digest)
aws ecr describe-images \
  --repository-name keda-demo-app \
  --region us-east-1 \
  --query 'imageDetails[*].[imageTags,imagePushedAt,imageSizeInBytes]' \
  --output table

# Delete a specific image tag
aws ecr batch-delete-image \
  --repository-name keda-demo-app \
  --region us-east-1 \
  --image-ids imageTag=sha-oldcommit

# Get the full repository URI
aws ecr describe-repositories \
  --repository-names keda-demo-app \
  --region us-east-1 \
  --query 'repositories[0].repositoryUri' \
  --output text

# Re-authenticate Docker (tokens expire after 12 hours)
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin \
    $(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com
```

---

## 8. Integration with EKS (Pull from ECR)

When you reference an ECR image in a Kubernetes Deployment:

```yaml
# manifests/deployment.yaml
spec:
  containers:
    - name: app
      image: 123456789012.dkr.ecr.us-east-1.amazonaws.com/keda-demo-app:sha-a1b2c3d
```

**How EKS pulls the image:**
1. kubelet sees the ECR URI
2. EKS worker node's IAM instance profile has `ecr:GetAuthorizationToken` permission
3. kubelet automatically calls ECR to get a pull token
4. Image is pulled — **no `imagePullSecrets` needed for same-account ECR**

This is a major advantage over Docker Hub: zero credential management for
pod image pulls when using ECR with EKS in the same account.

---

## References

- [ECR User Guide](https://docs.aws.amazon.com/AmazonECR/latest/userguide/what-is-ecr.html)
- [ECR Lifecycle Policies](https://docs.aws.amazon.com/AmazonECR/latest/userguide/LifecyclePolicies.html)
- [ECR Image Scanning](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-scanning.html)
- [EKS pulling from ECR](https://docs.aws.amazon.com/AmazonECR/latest/userguide/ECR_on_EKS.html)
