# Phase 2 — Image Trust and Supply Chain

9 labs covering the supply chain security gap between "image builds successfully" and "image is trustworthy." Built around a Jenkins + Bitbucket + ECR stack — the same stack used in production financial application deployments.

---

## The Core Problem

A pipeline that builds and pushes is not a secure pipeline. Without supply chain controls, any of these happen silently:

- A developer pushes an image from their laptop under a production tag
- An attacker with ECR credentials overwrites `webapp:v1.0.0` with a backdoored image
- A CVE is published for a package in a running image — nobody knows which images are affected
- An ECS task pulls a different image than what was last deployed because the tag was overwritten
- Dockerfile anti-patterns ship to ECR because nothing checked the Dockerfile before build

---

## Labs

| Lab | Finding | Risk | Type |
|-----|---------|------|------|
| [Lab 10](./lab10/lab10-missing-image-signatures.md) | Missing image signatures (Cosign) | High | Hands-on |
| [Lab 11](./lab11/lab11-no-sbom.md) | No SBOM attached to images | Medium | Hands-on |
| [Lab 12](./lab12/lab12-ecr-public-access.md) | ECR repository public access | Critical | Simulated |
| [Lab 13](./lab13/lab13-mutable-tags.md) | Mutable image tags in ECR | High | Simulated |
| [Lab 14](./lab14/lab14-imagepullpolicy.md) | ECS task deploys by tag not digest | High | Simulated |
| [Lab 15](./lab15/lab15-registry-auth.md) | Hardcoded AWS credentials in Jenkins | High | Simulated |
| [Lab 16](./lab16/lab16-ecr-scanning-lifecycle.md) | ECR missing scanning and lifecycle | Medium | Simulated |
| [Lab 17](./lab17/lab17-slsa-provenance.md) | Missing build provenance (SLSA) | High | Hybrid |
| [Lab 18](./lab18/lab18-dockerfile-linting-ci.md) | No Dockerfile linting in CI | Medium | Hands-on |

---

## Pipeline Files

| File | Description |
|------|-------------|
| `pipeline/Jenkinsfile.vulnerable` | Starting point — 9 supply chain gaps present |
| `pipeline/Jenkinsfile.fixed` | Production-ready hardened pipeline — all gaps resolved |
| `terraform/ecr-vulnerable.tf` | ECR with mutable tags, no scanning, public policy |
| `terraform/ecr-fixed.tf` | ECR hardened with immutable tags, lifecycle, KMS, VPC endpoints |

---

## Hands-On Evidence

Labs 10, 11, and 18 were run locally. Evidence files contain real tool output.

**Lab 10 — Cosign:**
- `pre-signing.txt` — `no signatures found` on unsigned image
- `signing.txt` — cosign signing output with key-based signing
- `post-signing.txt` — successful verification, signature visible in registry

**Lab 11 — SBOM:**
- `sbom.spdx.json` — 103 packages catalogued in SPDX-2.3 format
- `sbom-summary.txt` — package count, flask 3.0.3 found
- `sbom-attach.txt` — SBOM attached as cosign attestation

**Lab 18 — Dockerfile linting:**
- `hadolint-ci.txt` — clean Dockerfile: exit code 0
- `hadolint-vuln-vs-fixed.txt` — vulnerable Dockerfile: DL3007/DL3020/DL3042, exit code 1

---

## Tools

| Tool | Purpose | Labs |
|------|---------|------|
| `cosign` v3.0.6 | Image signing and attestation | 10, 11, 17 |
| `syft` v1.42.4 | SBOM generation (SPDX, CycloneDX) | 11 |
| `aws ecr` | Registry management, scanning, lifecycle | 12, 13, 15, 16 |
| `crane` | Digest retrieval, registry inspection | 10, 13 |
| `hadolint` v2.14.0 | Dockerfile linting in CI | 18 |
| `trivy` | Vulnerability scan gate in Jenkins | 05, 16 |

---

## Tool Gaps Found in Phase 2

**cosign v3.0.6 — cannot scan local images without a registry**
cosign verify against a local image tag attempts to pull from Docker Hub. A local OCI registry (`registry:2`) is required for local testing. In production with ECR this is not an issue.

**cosign v3.0.6 — sign by digest warning**
cosign warns when signing by tag rather than digest. In production Jenkinsfiles, always capture the digest immediately after push and sign by digest.

**ECR basic scanning misses application CVEs**
ECR basic scanning (Clair) checks OS packages only. npm, pip, and Maven dependencies are invisible to it. Enable Enhanced scanning (Amazon Inspector) for complete coverage.

**SLSA L3 not achievable with standard Jenkins**
Jenkins can achieve SLSA L2 — provenance generated and signed by the build service. L3 requires a hardened builder where the build process cannot be influenced by the calling workflow. This requires additional Jenkins node isolation controls not covered in these labs.

---

## Interview Corner — Phase 2 Key Questions

**Q: What's the difference between image signing and build provenance?**
Signing (Lab 10) proves the image wasn't modified after it left your hands. Provenance (Lab 17) proves where it came from before you signed it. You need both. An attacker with your cosign private key can sign a malicious image — it passes verification. With provenance, the attestation also records the Jenkins job, Bitbucket commit, and branch — all of which the attacker cannot forge without compromising the CI system itself.

**Q: Why use ECR immutable tags if we already sign images with cosign?**
Defence in depth. Immutable tags prevent the attack at the registry level — the overwrite fails with an API error before any image reaches a running container. Cosign signing catches tampering at the verification layer — the signature check fails when the image is pulled. Both controls catch different failure modes: immutable tags stop the overwrite, cosign catches cases where immutability was disabled or bypassed.

**Q: How does SBOM help with incident response in your ECR stack?**
A CVE drops for a package. Without SBOMs: pull every image from ECR, scan each one, wait for results. With SBOMs attached as cosign attestations: `cosign verify-attestation --type spdxjson` retrieves the pre-generated inventory and you query it directly — no image pull needed. For 50+ images across multiple ECR repositories, this cuts incident response time from hours to minutes.