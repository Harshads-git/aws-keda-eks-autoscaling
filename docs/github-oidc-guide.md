# GitHub OIDC Guide: Passwordless AWS Authentication for CI/CD

This guide explains how GitHub Actions authenticates with AWS without any
stored credentials, and the one-time setup steps to enable it.

---

## 1. Why OIDC? (The Problem with Static Keys)

```
❌ Traditional approach — AWS static keys in GitHub:
   AWS_ACCESS_KEY_ID     = AKIAXXXXXXXXXXXXXXXX
   AWS_SECRET_ACCESS_KEY = wJalrXUtnFEMI/K7MDENG/...

   Problems:
   • Keys never expire — a leak is permanent until manually rotated
   • Rotation requires updating multiple places (GitHub, .env, CI scripts)
   • Keys have no scope — they work from any IP, any service
   • GitHub is a 3rd party — storing AWS creds there is high-risk
```

```
✅ OIDC approach — GitHub generates JWTs, AWS validates and issues temp creds:

   GitHub Actions runtime
     → generates short-lived JWT (15-min expiry, auto-generated per job)
       → presented to AWS STS
         → STS validates JWT against GitHub OIDC public keys
           → STS checks trust policy: only your repo + main branch
             → STS returns temporary credentials (15-min, no renewal)

   Benefits:
   • Zero long-lived credentials stored anywhere
   • Each workflow run gets fresh credentials
   • Trust policy restricts to your specific repo and branch
   • CloudTrail shows GitHubActions-<run-id> — full audit trail
```

---

## 2. One-Time Setup (Run Before First CD Deployment)

### Step 1: Run `terraform apply`

The EKS cluster and IRSA roles must exist before CD can deploy:

```bash
cd terraform
terraform init
terraform apply -var-file=terraform.tfvars
```

### Step 2: Create GitHub Actions IAM Role

```bash
bash scripts/setup-github-oidc.sh
```

This creates:
- `IAM OIDC Provider` → GitHub becomes a trusted JWT issuer in your AWS account
- `IAM Role: github-actions-keda-demo` → CD assumes this role via OIDC

Expected output:
```
[1/3] Creating GitHub OIDC Identity Provider in AWS IAM ✔
[2/3] Creating IAM role: github-actions-keda-demo ✔
[3/3] Attaching minimum permissions ✔

Role ARN: arn:aws:iam::183264980:role/github-actions-keda-demo
```

### Step 3: Configure GitHub Secrets

```bash
# Requires GitHub CLI (brew install gh && gh auth login):
bash scripts/setup-github-secrets.sh

# Verify secrets are set:
bash scripts/setup-github-secrets.sh --verify
```

### Step 4: Trigger First Deployment

```bash
# Manual trigger (before any code change):
gh workflow run cd.yml --repo Harshads-git/aws-keda-eks-autoscaling

# Or just push a change to main:
git commit --allow-empty -m "ci: trigger initial cd deployment"
git push
```

---

## 3. How the OIDC Trust Policy Works

The IAM role trust policy restricts EXACTLY who can assume the role:

```json
{
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

| Actor | `sub` claim | Can assume role? |
|---|---|---|
| Push to `main` | `repo:Harshads-git/...:ref:refs/heads/main` | ✅ Yes |
| Push to `feature/x` | `repo:Harshads-git/...:ref:refs/heads/feature/x` | ❌ No |
| Fork PR | `repo:SomeOtherUser/...:ref:refs/...` | ❌ No |
| Another repo | `repo:AnotherOrg/...:ref:refs/...` | ❌ No |
| PR (not merged) | `repo:Harshads-git/...:pull_request` | ❌ No |

---

## 4. IAM Role Permissions Explained

The `github-actions-keda-demo` role has these minimum permissions:

| Permission | Why |
|---|---|
| `ecr:GetAuthorizationToken` | Docker login to ECR (account-wide action) |
| `ecr:PutImage` + layer upload actions | Push Docker image to ECR repo |
| `eks:DescribeCluster` | `aws eks update-kubeconfig` needs to read cluster endpoint |
| `sqs:GetQueueUrl` | CD can verify queue exists after deploy |

**Not included (and why):**
- `eks:UpdateNodegroupConfig` — CD doesn't scale nodes (KEDA does)
- `iam:*` — CD never creates IAM resources
- `s3:*` — CD never touches Terraform state
- `ec2:*` — CD never manages EC2 directly

---

## 5. Troubleshooting

### CD fails with `Error: Not authorized to perform sts:AssumeRoleWithWebIdentity`

**Cause:** OIDC provider doesn't exist in your AWS account yet.
```bash
# Check if provider exists:
aws iam list-open-id-connect-providers | grep github

# If missing, run:
bash scripts/setup-github-oidc.sh
```

### CD fails with `credentialScope must match the signing region`

**Cause:** `AWS_REGION` secret doesn't match the region where you created resources.
```bash
# Verify:
bash scripts/setup-github-secrets.sh --verify
# Check: AWS_REGION should match your terraform.tfvars aws_region value
```

### CD succeeds but kubectl fails with `Unauthorized`

**Cause:** The GitHub Actions IAM role isn't in the EKS `aws-auth` ConfigMap.
```bash
# Add github-actions role to EKS auth:
kubectl edit configmap aws-auth -n kube-system

# Add under mapRoles:
# - rolearn: arn:aws:iam::183264980:role/github-actions-keda-demo
#   username: github-actions
#   groups:
#     - system:masters  # or a more restricted group
```

### Secrets are set but CD still fails with `SQS_QUEUE_URL` error

**Cause:** Secret value was not updated after `terraform apply` changed the queue.
```bash
# Re-run secrets setup (idempotent — safe to re-run):
bash scripts/setup-github-secrets.sh
```

---

## 6. GitHub CLI Reference

```bash
# Authenticate:
gh auth login

# Check auth status:
gh auth status

# List all secrets (names only):
gh secret list --repo Harshads-git/aws-keda-eks-autoscaling

# Set a secret manually:
echo "my-value" | gh secret set MY_SECRET_NAME --repo Harshads-git/...

# Trigger CD workflow:
gh workflow run cd.yml

# Watch live logs:
gh run watch

# List recent CD runs:
gh run list --workflow=cd.yml
```

---

## 7. Security Hardening (Production Recommendations)

For a real production environment beyond this demo:

1. **Scope ECR permissions to exact repo ARN** (already done — `keda-demo*` prefix)

2. **Use GitHub Environments for manual approval**
   - Settings → Environments → `dev` → Required reviewers
   - Adds human gate between build and deploy

3. **Add `repo:...` Condition to sub** (already done — main branch only)

4. **Enable MFA delete on Terraform state bucket**
   ```bash
   aws s3api put-bucket-versioning \
     --bucket keda-demo-tfstate-183264980 \
     --versioning-configuration Status=Enabled,MFADelete=Enabled \
     --mfa "arn:aws:iam::183264980:mfa/my-device 123456"
   ```

5. **Set CloudTrail alerts** for `AssumeRoleWithWebIdentity` events
   - CloudWatch Alarm on `AssumeRoleWithWebIdentity` where `userAgent != "GitHub"`
   - Detects if someone tries to replay GitHub JWTs (they can't — 15-min expiry)
