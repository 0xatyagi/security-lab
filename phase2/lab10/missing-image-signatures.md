# Lab 10 — Missing Image Signatures (Cosign)

| Field | Value |
|-------|-------|
| **Risk Rating** | 🔴 High |
| **MITRE ATT&CK** | T1525 — Implant Internal Image |
| **CIS Benchmark** | CIS Kubernetes 5.5.1 — Ensure Image Provenance |
| **Tools Used** | `cosign`, `crane` |
| **Lab Type** | Hands-on |
| **Lab Completed** | April 2026 |

---

## What Is This?

Without image signing, there is no cryptographic proof that an image in ECR was built by your Jenkins pipeline and not by an attacker who gained push access. Tags are mutable — anyone with `ecr:PutImage` permissions can overwrite `webapp:v1.0.0` with a backdoored image. No alert fires. The next ECS task restart pulls the compromised image.

Cosign creates a cryptographic link between the image digest and a signing identity (a key pair in Jenkins, or an OIDC token in GitHub Actions). The signature is stored as an OCI artifact in the same ECR repository alongside the image.

---

## The Attack Path (Without Signing)

1. Attacker compromises Jenkins credentials or ECR push access
2. Builds a modified image locally with a backdoor
3. Pushes it under the same tag — `webapp:v1.0.0` now points to a different digest
4. ECS pulls it on next task restart — no verification occurs
5. Backdoored image runs in production — no alert, no audit trail

---

## Vulnerable Pipeline Stage

```groovy
// No signing after push — image is unauthenticated
stage('Push to ECR') {
    steps {
        sh """
            aws ecr get-login-password --region ${AWS_REGION} \
                | docker login --username AWS --password-stdin ${ECR_REGISTRY}
            docker push ${IMAGE_NAME}:${BUILD_NUMBER}
        """
        // GAP: no cosign sign step
        // Anyone with push access can overwrite this tag silently
    }
}
```

---

## Hands-On Evidence

### Step 1 — Before signing: no signatures found

```
Error: no signatures found
```

cosign verify returns an error — the image has no cryptographic attestation. Anyone who pulls this image has no proof of its origin.

### Step 2 — Image digest captured

```
sha256:53f02d3251ca0da44b4258a1fdc44d541dde541219d81ab3cdf6baf9bf0a5ad6
```

### Step 3 — Image signed

```
Enter password for private key:
Signing artifact...
```

cosign stored the signature as an OCI artifact in the registry alongside the image.

### Step 4 — Verification after signing

```
Verification for localhost:5001/lab10-webapp:v1.0.0 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The signatures were verified against the specified public key
[{"critical":{"identity":{"docker-reference":"localhost:5001/lab10-webapp:v1.0.0"},
  "image":{"docker-manifest-digest":"sha256:53f02d32..."},
  "type":"https://sigstore.dev/cosign/sign/v1"},"optional":{}}]
```

### Step 5 — Signature stored in registry

```
crane ls localhost:5001/lab10-webapp:
sha256-53f02d3251ca0da44b4258a1fdc44d541dde541219d81ab3cdf6baf9bf0a5ad6
v1.0.0
```

The `sha256-...` entry is the cosign signature stored as an OCI artifact. In ECR, this appears as a referrer attached to the image digest.

### Tool Gap Documented

cosign v3.0.6 warns when signing by tag rather than digest:
```
WARNING: Image reference uses a tag, not a digest, to identify the image to sign.
This can lead you to sign a different image than the intended one.
```

Production pattern: always sign by digest, not tag.

---

## Fixed Pipeline Stage

```groovy
stage('Build and Push') {
    steps {
        script {
            sh """
                docker build -t ${IMAGE_NAME}:${BUILD_NUMBER} .
                aws ecr get-login-password --region ${AWS_REGION} \
                    | docker login --username AWS --password-stdin ${ECR_REGISTRY}
                docker push ${IMAGE_NAME}:${BUILD_NUMBER}
            """
            // Capture digest — sign by digest, not tag
            env.IMAGE_DIGEST = sh(
                script: "aws ecr describe-images \
                    --repository-name ${ECR_REPO} \
                    --image-ids imageTag=${BUILD_NUMBER} \
                    --query 'imageDetails[0].imageDigest' \
                    --output text",
                returnStdout: true
            ).trim()
        }
    }
}

stage('Sign Image') {
    steps {
        withCredentials([file(credentialsId: 'cosign-private-key', variable: 'COSIGN_KEY')]) {
            sh """
                # Sign by digest — not tag
                COSIGN_PASSWORD='' cosign sign \
                    --key ${COSIGN_KEY} \
                    ${IMAGE_NAME}@${IMAGE_DIGEST}
            """
        }
    }
}

stage('Verify Before Deploy') {
    steps {
        withCredentials([file(credentialsId: 'cosign-public-key', variable: 'COSIGN_PUB')]) {
            sh """
                cosign verify \
                    --key ${COSIGN_PUB} \
                    ${IMAGE_NAME}@${IMAGE_DIGEST}
            """
        }
    }
}
```

### Key Management in Jenkins

```groovy
// Store cosign keys as Jenkins credentials
// cosign-private-key → Secret file credential
// cosign-public-key  → Secret file credential

// Generate key pair (run once, store in Jenkins)
// cosign generate-key-pair
// Private key → Jenkins credential
// Public key  → commit to repo (it is public)
```

### ECR — Verify Signature Exists

```bash
# Simulated — requires AWS CLI with ECR access
aws ecr describe-images \
    --repository-name webapp \
    --image-ids imageDigest=sha256:53f02d32... \
    --query 'imageDetails[0].imageTags'

# Check cosign referrers in ECR
cosign verify \
    --key cosign.pub \
    123456789012.dkr.ecr.us-east-1.amazonaws.com/webapp@sha256:53f02d32...
```

## Cleanup

```bash
docker stop local-registry
docker rm local-registry
docker rmi lab10-webapp:v1.0.0 localhost:5001/lab10-webapp:v1.0.0
rm -f lab10/cosign.key lab10/cosign.pub
```
