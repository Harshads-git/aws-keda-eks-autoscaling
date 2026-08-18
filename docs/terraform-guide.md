# Terraform Guide: Infrastructure as Code for the KEDA Demo

This guide covers how Terraform is used in this project, the module structure,
state management strategy, and a realistic AWS cost breakdown to stay within
the Free Tier as much as possible.

---

## 1. Module Structure

```
terraform/
├── main.tf                    ← Root module: composes all sub-modules
├── variables.tf               ← All input variable definitions
├── outputs.tf                 ← Exposes key values (VPC IDs, EKS endpoint)
├── terraform.tfvars.example   ← Template — copy to terraform.tfvars
└── modules/
    ├── vpc/                   ← Day 8: VPC, subnets, NAT, IGW, route tables
    ├── sqs/                   ← Day 9: SQS queue, DLQ, IAM policies
    ├── eks/                   ← Days 10-12: EKS cluster, node groups
    └── irsa/                  ← Days 13-14: IAM roles for K8s service accounts
```

**Why modules?** Each module is independently testable and reusable. The root
`main.tf` is purely compositional — no resource definitions, only module calls.

---

## 2. Terraform Commands

### First-time setup

```bash
cd terraform

# Copy and fill in your values
cp terraform.tfvars.example terraform.tfvars

# Download providers and initialize modules
terraform init

# Preview all resources that will be created
terraform plan -var-file=terraform.tfvars

# Create the infrastructure
terraform apply -var-file=terraform.tfvars
```

### Day-to-day

```bash
# Preview changes before applying
terraform plan -var-file=terraform.tfvars

# Apply changes (will ask for confirmation)
terraform apply -var-file=terraform.tfvars

# Apply without confirmation prompt (use in CI only)
terraform apply -var-file=terraform.tfvars -auto-approve

# See all outputs after apply
terraform output

# Get a specific output
terraform output -raw vpc_id
```

### Teardown (destroys ALL infrastructure)

```bash
# Preview what will be destroyed
terraform plan -destroy -var-file=terraform.tfvars

# DESTROY EVERYTHING (irreversible — EKS, VPC, SQS all deleted)
terraform destroy -var-file=terraform.tfvars
```

---

## 3. State Management

Terraform state (`terraform.tfstate`) tracks every AWS resource it manages.

### Local State (Days 8-9, solo development)

```
terraform/
└── terraform.tfstate     ← Created after first 'terraform apply'
                             Gitignored — NEVER commit this file
```

**Problems with local state:**
- Lost if your laptop is stolen or HDD fails
- Cannot share with CI/CD or team members
- Concurrent `terraform apply` runs corrupt the state

### S3 Backend (Day 9+, recommended)

```hcl
# terraform/main.tf — uncomment on Day 9
backend "s3" {
  bucket         = "keda-demo-tfstate-183264980"  # Your account ID
  key            = "aws-keda-eks-autoscaling/terraform.tfstate"
  region         = "us-east-1"
  encrypt        = true
  dynamodb_table = "keda-demo-tfstate-lock"
}
```

**S3 backend advantages:**
- State stored durably in S3 (99.999999999% durability)
- `encrypt = true`: state file encrypted at rest (contains sensitive data!)
- DynamoDB table provides state locking: prevents two `terraform apply` runs
  from corrupting state simultaneously

```
Developer A runs: terraform apply
  → acquires lock in DynamoDB (LockID: keda-demo-tfstate)
Developer B runs: terraform apply
  → "Error: state is already locked by Developer A" ← safe, blocked
Developer A finishes → releases lock
Developer B can now apply
```

---

## 4. AWS Cost Breakdown (Free Tier Analysis)

> ⚠️ EKS is **not** fully Free Tier. This project has **unavoidable costs**.
> Plan for approximately **$5-15/month** during development.

### Free Tier Resources ✅

| Resource | Free Tier | This Project |
|---|---|---|
| VPC | Free | 1 VPC |
| Subnets (4) | Free | 4 subnets |
| Internet Gateway | Free | 1 IGW |
| Route Tables | Free | 3 route tables |
| SQS (Standard) | 1M requests/month free | ~1,000 requests (testing only) |
| ECR | 500 MB/month free | ~120 MB image |
| CloudWatch Logs | 5 GB/month free | Minimal logs |

### Paid Resources 💰

| Resource | Cost | Monthly Estimate |
|---|---|---|
| **EKS Control Plane** | $0.10/hr | **~$72/month** |
| **NAT Gateway** | $0.045/hr + data | **~$33/month** |
| EC2 t3.micro (1 node) | $0.0104/hr | **~$7.50/month** |
| Elastic IP (NAT) | $0.005/hr when unassociated | ~$0 (always associated) |
| **Total estimate** | | **~$112/month** |

### Cost Minimisation Strategy (this project)

```bash
# Only run the cluster when actively working (Day 16+)
# Destroy when not in use:
terraform destroy -var-file=terraform.tfvars

# Or scale the node group to 0 when not testing:
aws eks update-nodegroup-config \
  --cluster-name keda-demo-cluster \
  --nodegroup-name keda-demo-nodes \
  --scaling-config minSize=0,maxSize=3,desiredSize=0
```

**Total cost for this 30-day project (running cluster only Days 16-30):**
- EKS active for ~15 days × 24 hrs × $0.10 = **~$36**
- NAT active for ~15 days × 24 hrs × $0.045 = **~$16**
- t3.micro for ~15 days × 24 hrs × $0.0104 = **~$3.75**
- **Total: ~$55** for the full 30-day project

---

## 5. Terraform vs Manual AWS CLI (Why Terraform)

```bash
# Manual approach (scripts/setup-sqs.sh)
aws sqs create-queue --queue-name keda-demo-queue
aws sqs set-queue-attributes ...  # 5+ separate commands
# Problem: how do you delete it? How do you track what you created?

# Terraform approach
resource "aws_sqs_queue" "main" { name = "keda-demo-queue" }
# terraform apply  → creates queue
# terraform destroy → deletes queue
# terraform plan   → shows drift from desired state
```

**Key Terraform benefits for this project:**

1. **Idempotency:** `terraform apply` twice = same result (no duplicate resources)
2. **Drift detection:** `terraform plan` shows if someone manually changed AWS
3. **Dependency graph:** Terraform knows EKS needs VPC → creates VPC first automatically
4. **Destroy:** `terraform destroy` removes everything cleanly, in the right order
5. **State:** Every resource ID is tracked — no hunting in the AWS console

---

## 6. What Gets Created Per Module (Day Reference)

```
Day 8:  terraform/modules/vpc/    VPC, subnets, IGW, NAT, routes
Day 9:  terraform/modules/sqs/    SQS queue, DLQ, IAM policies, S3 state bucket
Day 10: terraform/modules/eks/    EKS cluster, IAM roles
Day 11: terraform/modules/eks/    Node groups (managed, t3.micro)
Day 12: terraform/modules/eks/    EKS add-ons (CoreDNS, kube-proxy, VPC CNI)
Day 13: terraform/modules/irsa/   IRSA role for consumer pods (sqs:ReceiveMessage)
Day 14: terraform/modules/irsa/   IRSA role for KEDA operator (sqs:GetQueueAttributes)
```

---

## References

- [Terraform AWS Provider Docs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [EKS VPC Requirements](https://docs.aws.amazon.com/eks/latest/userguide/network_reqs.html)
- [Terraform S3 Backend](https://developer.hashicorp.com/terraform/language/settings/backends/s3)
- [AWS Free Tier Details](https://aws.amazon.com/free/)
