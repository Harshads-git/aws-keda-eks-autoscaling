# EKS Setup Guide: From Zero to Running Cluster

This guide walks you through provisioning the complete AWS infrastructure
for the KEDA autoscaling demo — from a fresh AWS account to a running
Kubernetes cluster with KEDA installed.

Estimated time: **45-60 minutes** (most of which is waiting for EKS to provision)

---

## Prerequisites

Before starting, verify all tools are installed:

```bash
bash scripts/check-prerequisites.sh
```

The script validates: `aws`, `kubectl`, `helm`, `terraform`, `docker`.

---

## Phase 1: One-Time Bootstrap (Day 1)

### 1.1 Configure AWS CLI

```bash
aws configure
# AWS Access Key ID:     <your key>
# AWS Secret Access Key: <your secret>
# Default region:        us-east-1
# Default output format: json

# Verify:
aws sts get-caller-identity
```

### 1.2 Set Up Terraform Remote State

Run once — creates the S3 bucket and DynamoDB table:

```bash
bash scripts/setup-terraform-state.sh
```

Expected output:
```
[1/5] Creating S3 state bucket: keda-demo-tfstate-183264980 ✔
[2/5] Enabling versioning ✔
[3/5] Enabling server-side encryption (AES-256) ✔
[4/5] Blocking all public access ✔
[5/5] Creating DynamoDB lock table ✔
```

### 1.3 Enable the S3 Backend

Edit `terraform/backend.tf` — replace `YOUR_ACCOUNT_ID` with your AWS account ID:

```bash
# Get your account ID:
aws sts get-caller-identity --query Account --output text
# Example: 183264980

# Edit terraform/backend.tf:
# bucket = "keda-demo-tfstate-183264980"  ← replace YOUR_ACCOUNT_ID
```

---

## Phase 2: Provision Infrastructure

### 2.1 Copy and Configure Variables

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars — defaults are fine for dev, no changes needed
```

### 2.2 Initialize Terraform

```bash
cd terraform
terraform init
```

Expected: Terraform asks to migrate local state to S3:
```
Do you want to copy existing state to the new backend?
  Enter a value: yes
```

### 2.3 Preview the Infrastructure

```bash
terraform plan -var-file=terraform.tfvars
```

You'll see **~35 resources** to create:
- VPC, 4 subnets, IGW, NAT, 3 route tables
- SQS queue + DLQ + 2 IAM policies + 1 CloudWatch alarm
- EKS cluster role, cluster, node group role, node group, OIDC provider
- 4 EKS add-ons, 2 IRSA roles

### 2.4 Apply

```bash
terraform apply -var-file=terraform.tfvars
```

> ⏱️ **EKS cluster takes 10-15 minutes to provision.** Grab a coffee.

Expected output (at the end):
```
Apply complete! Resources: 35 added, 0 changed, 0 destroyed.

Outputs:
cluster_name           = "keda-demo-dev-cluster"
kubeconfig_command     = "aws eks update-kubeconfig ..."
consumer_role_arn      = "arn:aws:iam::183264980:role/keda-demo-dev-app-role"
keda_operator_role_arn = "arn:aws:iam::183264980:role/keda-demo-dev-keda-operator-role"
sqs_queue_url          = "https://sqs.us-east-1.amazonaws.com/..."
```

---

## Phase 3: Configure kubectl

```bash
# Configure kubectl to talk to your new cluster:
terraform output -raw kubeconfig_command | bash

# Verify connection:
kubectl get nodes
# NAME                          STATUS   ROLES    AGE   VERSION
# ip-10-0-3-xxx.ec2.internal    Ready    <none>   5m    v1.29.x
```

---

## Phase 4: Install KEDA

```bash
# Set the KEDA operator role ARN (reads from terraform output automatically):
export KEDA_OPERATOR_ROLE_ARN=$(terraform output -raw keda_operator_role_arn)

cd ..  # back to project root
bash scripts/install-keda.sh
```

Expected:
```
[1/4] Adding KEDA Helm repository ✔
[2/4] Creating KEDA namespace ✔
[3/4] Installing KEDA ✔
[4/4] Verifying KEDA installation...

  Pods in keda namespace:
  NAME                                      READY   STATUS    RESTARTS   AGE
  keda-operator-xxxx                        1/1     Running   0          60s
  keda-metrics-apiserver-xxxx               1/1     Running   0          60s
  keda-admission-webhooks-xxxx              1/1     Running   0          60s
```

---

## Phase 5: Deploy the Application

### 5.1 Build and Push the Container Image

```bash
# Set required environment variables:
export ECR_REPO_URI=$(aws ecr describe-repositories \
  --repository-names keda-demo \
  --query 'repositories[0].repositoryUri' \
  --output text)

bash scripts/build-and-push.sh
```

### 5.2 Update the ServiceAccount Annotation

Get the consumer role ARN and update the manifest:

```bash
CONSUMER_ROLE_ARN=$(cd terraform && terraform output -raw consumer_role_arn)
echo $CONSUMER_ROLE_ARN
# Copy this ARN into manifests/serviceaccount.yaml:
#   eks.amazonaws.com/role-arn: arn:aws:iam::183264980:role/keda-demo-dev-app-role
```

### 5.3 Deploy All Manifests

```bash
export SQS_QUEUE_URL=$(cd terraform && terraform output -raw sqs_queue_url)
export IMAGE_TAG=latest

bash scripts/deploy-all-manifests.sh
```

---

## Phase 6: Test Autoscaling

### 6.1 Watch Pods in Real Time

```bash
# Terminal 1: watch pods
kubectl get pods -n keda-demo -w

# Terminal 2: watch ScaledObject status
kubectl get scaledobject -n keda-demo -w
```

### 6.2 Send Messages to Trigger Scaling

```bash
# Send 25 messages (target queueLength=5 → should scale to 5 pods)
bash scripts/generate-messages.sh --count 25
```

### 6.3 Observe Scale-Up

```
NAME                          READY   STATUS    RESTARTS   AGE
keda-demo-xxxx                0/1     Pending   0          5s   ← KEDA scaled up
keda-demo-yyyy                0/1     Pending   0          5s
keda-demo-zzzz                1/1     Running   0          15s
```

### 6.4 Observe Scale-to-Zero

Once all messages are processed:
```bash
# After ~5 minutes with empty queue:
kubectl get pods -n keda-demo
# No resources found in keda-demo namespace.  ← scaled to zero!
```

---

## Troubleshooting

### Pods stuck in Pending
```bash
kubectl describe pod <pod-name> -n keda-demo
# Look for: "Insufficient memory" → upgrade to t3.small
# Look for: "No nodes available" → check node group in EC2 console
```

### KEDA not scaling
```bash
# Check KEDA operator logs:
kubectl logs -n keda deploy/keda-operator -f

# Check ScaledObject status:
kubectl describe scaledobject keda-demo -n keda-demo
# Look for: "KEDA operator is checking for the queue depth"
```

### IRSA not working (AccessDenied)
```bash
# Check the SA annotation matches the IRSA trust policy:
kubectl get sa keda-demo -n keda-demo -o yaml
# Should have: eks.amazonaws.com/role-arn: arn:aws:iam::...

# Check the OIDC condition in the IAM role trust policy:
aws iam get-role --role-name keda-demo-dev-app-role \
  --query 'Role.AssumeRolePolicyDocument'
# sub should be: system:serviceaccount:keda-demo:keda-demo
```

### SQS queue not found
```bash
# Verify queue exists:
aws sqs get-queue-url --queue-name keda-demo-queue

# If missing, the Terraform apply may not have included the SQS module.
# Check: terraform state list | grep sqs
```

---

## Cost Control: Destroy When Done

```bash
cd terraform

# Remove KEDA first (Helm):
helm uninstall keda --namespace keda

# Delete all K8s resources:
kubectl delete namespace keda-demo
kubectl delete namespace keda

# Destroy all Terraform infrastructure:
terraform destroy -var-file=terraform.tfvars
```

> ⚠️ **Do not forget to destroy!** EKS control plane costs $0.10/hour even when idle.
> At 24 hours/day: $2.40/day = $72/month just for the control plane.
