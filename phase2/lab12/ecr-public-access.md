# Lab 12 — Container Registry Public Access

| Field | Value |
|-------|-------|
| **Risk Rating** | 🔴 Critical |
| **MITRE ATT&CK** | T1530 — Data from Cloud Storage Object |
| **CIS Benchmark** | CIS AWS 2.1.1 — ECR Repository Policy |
| **Tools Used** | `aws ecr`, `crane`, `trivy` |
| **Lab Type** | Simulated (requires AWS CLI) |
| **Lab Completed** | April 2026 |

---

## What Is This?

An ECR repository with `Principal: "*"` in its policy is publicly readable. Anyone on the internet with the repository URI can pull every image without authentication. Container images are rich targets — they contain application code, configuration, internal hostnames, dependency trees, and sometimes hardcoded credentials.

This is not theoretical. Public ECR repositories appear in bug bounty reports regularly. A single misconfigured repository policy exposes the entire image history.

---

## Vulnerable Configuration

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowPublicPull",
    "Effect": "Allow",
    "Principal": "*",
    "Action": [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability"
    ]
  }]
}
```

Anyone can pull without credentials:

```bash
crane pull 123456789012.dkr.ecr.us-east-1.amazonaws.com/webapp:v1.0.0 webapp.tar
# No authentication required — downloads successfully
```

---

## Detection

```bash
# Audit all ECR repositories for public policies
for repo in $(aws ecr describe-repositories \
    --query 'repositories[].repositoryName' --output text); do
    policy=$(aws ecr get-repository-policy \
        --repository-name "$repo" \
        --query 'policyText' --output text 2>/dev/null)
    if echo "$policy" | grep -q '"Principal": "\*"'; then
        echo "PUBLIC: $repo"
    fi
done

# Expected output for vulnerable repo:
# PUBLIC: webapp
```

### Simulated Evidence

```
# aws ecr get-repository-policy --repository-name webapp
{
    "registryId": "123456789012",
    "repositoryName": "webapp",
    "policyText": "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"AllowPublicPull\",
    \"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":[\"ecr:GetDownloadUrlForLayer\",
    \"ecr:BatchGetImage\",\"ecr:BatchCheckLayerAvailability\"]}]}"
}
```

---

## Fix

```bash
# Remove the public policy
aws ecr delete-repository-policy \
    --repository-name webapp \
    --region us-east-1

# Verify anonymous pull now fails
crane pull 123456789012.dkr.ecr.us-east-1.amazonaws.com/webapp:latest test.tar
# Error: UNAUTHORIZED: authentication required
```

ECR repositories are private by default when no policy is set. Access is controlled through IAM policies on the pulling identity — ECS task roles, EC2 instance profiles, or cross-account role assumptions.

### Terraform Fix

See `terraform/ecr-fixed.tf` — no repository policy is defined. Private by default.

### SCP to Prevent Public ECR Across the Organisation

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyPublicECR",
    "Effect": "Deny",
    "Action": "ecr:SetRepositoryPolicy",
    "Resource": "*",
    "Condition": {
      "StringLike": {
        "ecr:policyText": "*\"Principal\":\"*\"*"
      }
    }
  }]
}
```

Apply this SCP at the AWS Organisation level to prevent any account from creating public ECR policies.

---

## Jenkins Pipeline — Verify No Public Policy

```groovy
stage('Security Gate — ECR Policy Check') {
    steps {
        script {
            def policy = sh(
                script: """
                    aws ecr get-repository-policy \
                        --repository-name ${ECR_REPO} \
                        --query 'policyText' \
                        --output text 2>/dev/null || echo 'NO_POLICY'
                """,
                returnStdout: true
            ).trim()

            if (policy.contains('"Principal":"*"') ||
                policy.contains('"Principal": "*"')) {
                error("SECURITY GATE FAILED: ECR repository ${ECR_REPO} has public access policy")
            }
            echo "ECR policy check passed — no public access"
        }
    }
}
```
