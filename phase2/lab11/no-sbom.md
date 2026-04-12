# Lab 11 — No SBOM Attached to Images

| Field | Value |
|-------|-------|
| **Risk Rating** | 🟡 Medium |
| **MITRE ATT&CK** | T1195.002 — Supply Chain Compromise |
| **CIS Benchmark** | CIS Supply Chain Security 4.2 — Software Bill of Materials |
| **Tools Used** | `syft`, `cosign`, `grype` |
| **Lab Type** | Hands-on |
| **Lab Completed** | April 2026 |

---

## What Is This?

A new CVE drops for a package. The question is: which of our images contain it? Without SBOMs attached to images, answering this means pulling and re-scanning every image from scratch. With SBOMs pre-generated and attached at build time, the answer takes seconds.

A Software Bill of Materials (SBOM) is a machine-readable inventory of every package inside a container image — OS packages, Python libraries, transitive dependencies. Generated at build time with syft, attached to the image as an OCI artifact with cosign, queryable during incident response without pulling the full image.

This is also a compliance gap. EU Cyber Resilience Act and US Executive Order 14028 both require SBOM generation and distribution for software sold to government entities.

---

## Hands-On Evidence

### SBOM Generated

```
Total packages: 103
SPDX version: SPDX-2.3
Document name: lab10-webapp

First 10 packages:
  adduser 3.152
  apt 3.0.3
  base-files 13.8+deb13u4
  base-passwd 3.6.7
  ...
```

103 packages catalogued in SPDX-2.3 format — OS packages plus Python dependencies.

### Flask Found in SBOM

```
Flask packages found: 1
  flask 3.0.3
```

During a CVE incident: "which images contain flask < 3.1.0?" — answered from the attached SBOM without pulling or re-scanning the image.

### SBOM Attached to Image

```
Using payload from: lab11/evidence/sbom.spdx.json
Signing artifact...
```

The SBOM is attached as a cosign attestation — stored as an OCI artifact in the registry alongside the image and signature.

---

## Vulnerable Pipeline Stage

```groovy
stage('Push to ECR') {
    steps {
        sh "docker push ${IMAGE_NAME}:${BUILD_NUMBER}"
        // GAP: no SBOM generation
        // GAP: no SBOM attachment to image
        // During incident response: must re-scan every image from scratch
    }
}
```

---

## Fixed Pipeline Stage

```groovy
stage('Generate and Attach SBOM') {
    steps {
        sh """
            # Generate SBOM in SPDX JSON format
            syft ${IMAGE_NAME}:${BUILD_NUMBER} \
                -o spdx-json \
                > sbom-spdx.json

            # Also generate CycloneDX for tools that prefer it
            syft ${IMAGE_NAME}:${BUILD_NUMBER} \
                -o cyclonedx-json \
                > sbom-cdx.json
        """

        withCredentials([file(credentialsId: 'cosign-private-key', variable: 'COSIGN_KEY')]) {
            sh """
                # Attach SBOM as signed attestation
                COSIGN_PASSWORD='' cosign attest \
                    --key ${COSIGN_KEY} \
                    --predicate sbom-spdx.json \
                    --type spdxjson \
                    ${IMAGE_NAME}@${IMAGE_DIGEST}
            """
        }

        // Archive SBOM as Jenkins build artifact
        archiveArtifacts artifacts: 'sbom-*.json', fingerprint: true
    }
}

stage('Scan SBOM for CVEs') {
    steps {
        sh """
            # Scan SBOM directly — faster than scanning the full image
            grype sbom:sbom-spdx.json \
                --fail-on=critical \
                --output table
        """
    }
}
```

### Query SBOM During Incident Response

```bash
# Simulated — ECR with cosign attestation
# "Which images contain flask < 3.1.0?"

cosign verify-attestation \
    --key cosign.pub \
    --type spdxjson \
    123456789012.dkr.ecr.us-east-1.amazonaws.com/webapp@sha256:53f02d32... \
    | jq '.payload | @base64d | fromjson | .packages[] | select(.name == "flask")'

# Expected output:
# {
#   "name": "flask",
#   "versionInfo": "3.0.3",
#   "SPDXID": "SPDXRef-Package-python-flask-3.0.3"
# }
```

---

## SPDX vs CycloneDX

| Format | Use Case |
|--------|---------|
| SPDX | Default syft output, better for licence compliance |
| CycloneDX | Better tooling support for vulnerability correlation |

Generate both. Store both. Different tools in your security stack will prefer different formats.
