# AWS Setup Guide

This guide walks you through everything needed to run this project safely within
the AWS Free Tier. Follow each section in order before running any scripts.

---

## Table of Contents

1. [AWS Account Setup](#1-aws-account-setup)
2. [IAM Admin User Creation](#2-iam-admin-user-creation)
3. [MFA Setup (Highly Recommended)](#3-mfa-setup)
4. [Billing Alarm — Protect Against Surprise Charges](#4-billing-alarm)
5. [AWS CLI Configuration](#5-aws-cli-configuration)
6. [Free Tier Limits Reference](#6-free-tier-limits-reference)
7. [Cost Expectations for This Project](#7-cost-expectations)

---

## 1. AWS Account Setup

### Create a Free Tier Account
1. Go to [https://aws.amazon.com/free](https://aws.amazon.com/free)
2. Click **"Create a Free Account"**
3. Fill in email, password, account name
4. Enter a valid credit/debit card (required, but won't be charged within Free Tier limits)
5. Choose **Basic Support** (free)
6. Account activation takes **up to 24 hours** — you'll get an email

### After Activation
- Log in at [https://console.aws.amazon.com](https://console.aws.amazon.com)
- You are logged in as the **Root user** — we will NOT use this for daily work

> ⚠️ **NEVER use the root account for regular operations.**
> Root has unlimited power and cannot be restricted by IAM policies.
> Create an IAM admin user (next section) and use that instead.

---

## 2. IAM Admin User Creation

The root account should only be used to create this first IAM user.

### Step-by-Step

1. In the AWS Console, search for **IAM** and open it
2. Click **Users** → **Create user**
3. Set **Username**: `admin-harshad` (or your preferred name)
4. Check ✅ **Provide user access to the AWS Management Console**
5. Select **"I want to create an IAM user"**
6. Set a strong password, uncheck "must reset password"
7. Click **Next**
8. On Permissions page → Click **"Attach policies directly"**
9. Search for `AdministratorAccess` → check it ✅
10. Click **Next** → **Create user**
11. **Download the CSV** with the login URL, username, and password — save this securely

### Create Access Keys for CLI

1. Click on your newly created user → **Security credentials** tab
2. Scroll to **Access keys** → **Create access key**
3. Select **"Command Line Interface (CLI)"** → confirm the warning → Next
4. Set description tag: `keda-project-local`
5. **Download the CSV** with `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`

> ⚠️ This is the ONLY time you can see the secret key. Save it now.

---

## 3. MFA Setup

Multi-Factor Authentication adds a second layer of protection.

### Enable MFA on Root Account
1. Log in as root → Click your account name (top right) → **Security credentials**
2. Under **Multi-factor authentication (MFA)** → **Assign MFA device**
3. Choose **Authenticator app** (Google Authenticator, Authy, etc.)
4. Scan the QR code → Enter two consecutive 6-digit codes → **Add MFA**

### Enable MFA on IAM Admin User
1. IAM → Users → your admin user → **Security credentials**
2. **Multi-factor authentication (MFA)** → **Assign MFA device**
3. Same process as above

---

## 4. Billing Alarm

This is **critical** — it protects you from unexpected charges.

### Enable Billing Alerts First
1. Log in as **root** (required for billing settings)
2. Click account name → **Account** → scroll to **IAM user and role access to Billing information**
3. Click **Edit** → check ✅ **Activate IAM Access** → **Update**
4. Click account name → **Billing and Cost Management**
5. Left sidebar → **Billing preferences** → check ✅ **Receive Free Tier Usage Alerts**
6. Enter your email → **Save preferences**

### Create a CloudWatch Billing Alarm
1. Switch to **us-east-1 region** (billing metrics only exist here)
2. Go to **CloudWatch** → **Alarms** → **Create alarm**
3. Click **Select metric** → **Billing** → **Total Estimated Charge** → **USD** → Select metric
4. Set conditions:
   - Threshold type: **Static**
   - Whenever EstimatedCharges is **Greater** than `5` (USD)
5. Configure actions → **Create new SNS topic**
   - Topic name: `billing-alert`
   - Email: your email address
   - Click **Create topic**
6. Alarm name: `monthly-spend-over-5usd`
7. Click **Create alarm**
8. **Check your email** and confirm the SNS subscription

> 💡 Set the alarm at $5 — it fires well before any serious charges accumulate.

---

## 5. AWS CLI Configuration

### Install AWS CLI v2 (if not already installed)

**Windows:**
```powershell
winget install Amazon.AWSCLI
# OR download from:
# https://awscli.amazonaws.com/AWSV2-installer.msi
```

**Verify installation:**
```bash
aws --version
# Expected: aws-cli/2.x.x Python/3.x.x
```

### Configure CLI with Your IAM User Credentials

```bash
aws configure
```

Enter when prompted:
```
AWS Access Key ID:     [paste from the CSV you downloaded]
AWS Secret Access Key: [paste from the CSV you downloaded]
Default region name:   us-east-1
Default output format: json
```

### Verify Configuration Works

```bash
# Should return your IAM user ARN
aws sts get-caller-identity
```

Expected output:
```json
{
  "UserId": "AIDAXXXXXXXXXXXXXXXXX",
  "Account": "123456789012",
  "Arn": "arn:aws:iam::123456789012:user/admin-harshad"
}
```

> ⚠️ If you see `root` in the Arn, you've configured the root account keys.
> Delete those keys, create IAM user access keys, and reconfigure.

---

## 6. Free Tier Limits Reference

| Service | Free Tier Allowance | This Project's Usage |
|---|---|---|
| **EC2 t2.micro / t3.micro** | 750 hrs/month (12 months) | ~1 hr/day × 30 days = 30 hrs ✅ |
| **Amazon SQS** | 1 million requests/month | ~1,000 requests ✅ |
| **Amazon ECR** | 500 MB storage/month | ~50 MB ✅ |
| **AWS Data Transfer** | 100 GB out/month | Minimal ✅ |
| **Amazon CloudWatch** | 10 custom metrics, 1M API requests | Within limits ✅ |
| **EKS Control Plane** | ❌ **NOT free** — $0.10/hour | ~$2.40 for project |
| **NAT Gateway** | ❌ **NOT free** — $0.045/hour + data | Optional, ~$1/day |
| **S3 (Terraform state)** | 5 GB storage, 20K GET, 2K PUT | Minimal ✅ |
| **DynamoDB (TF lock)** | 25 GB storage, 25 RCU/WCU | Minimal ✅ |

### Free Tier Optimization Tips

1. **Run `terraform destroy` after each day's session** — EKS costs $0.10/hr even when idle
2. **Skip NAT Gateway** for this project — use a simpler public subnet setup for learning
3. **Delete ECR images** older than your current tag using lifecycle policies
4. **Set EKS node count to 1** (minimum) during development

---

## 7. Cost Expectations

### Worst Case (leaving EKS running 24/7 for 30 days)
```
EKS Control Plane: $0.10/hr × 720 hrs = $72.00
EC2 t3.micro (1 node): Free Tier (750 hrs)
SQS: Free Tier
ECR: Free Tier
Total worst case: ~$72/month
```

### Recommended Usage (1 hr/day, destroy after each session)
```
EKS Control Plane: $0.10/hr × 30 hrs = $3.00
EC2 t3.micro: Free Tier
SQS: Free Tier
ECR: Free Tier
Total recommended: ~$3.00 for the entire project
```

> 🎯 **Best practice:** Add `terraform destroy` as the last step in each day's session.
> The `scripts/cleanup.sh` script (Day 21) will automate this for you.

---

## Next Steps

Once AWS CLI is configured and verified:
1. Copy `.env.example` to `.env` and fill in your values
2. Run `bash scripts/check-prerequisites.sh` to validate your full toolchain
3. Proceed to Day 3: SQS queue provisioning

---

## Troubleshooting

### "Unable to locate credentials"
```bash
aws configure list   # Check if credentials are set
cat ~/.aws/credentials  # Verify the credentials file
```

### "Access Denied" on aws sts get-caller-identity
Your IAM user may not have sufficient permissions. Ensure `AdministratorAccess` policy is attached.

### Region Mismatch
Always verify your region:
```bash
aws configure get region
# Should return: us-east-1 (or your chosen region)
```
