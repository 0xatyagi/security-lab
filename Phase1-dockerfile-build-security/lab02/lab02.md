# Lab 02 — Using :latest or Untagged Base Images

| Field | Value |
|-------|-------|
| **Risk Rating** | 🟡 Medium |
| **CIS Docker Benchmark** | 4.7 — Ensure update instructions are not used alone in the Dockerfile |
| **MITRE ATT&CK** | Supply Chain Compromise |
| **Tools Used** | `hadolint`, `dockle`, `trivy`, `crane` |
| **crane version** | 0.21.3 |
| **Lab Completed** | March 2026 |

---

## What Is This?

`FROM python:latest` and `FROM node` (no tag at all) both resolve to the `:latest` tag, which is **mutable**. Today it points to one digest. Next week it may point to a completely different image with different packages, different CVEs, and potentially compromised content — with no warning during `docker build`.

This is a **supply chain problem**. A mutable tag means:
- Every `docker build` can pull a different base image silently
- Builds are non-deterministic — you cannot reproduce a previous build
- A compromised upstream push to `:latest` flows into your next build automatically
- You have no audit trail of exactly which base image each build used

The only truly immutable reference is a **digest pin**:

```dockerfile
FROM python:3.12-slim@sha256:3d5ed973e45820f5ba5e46bd065bd88b3a504ff0724d85980dcd05eab361fcf4
```

---

## Root Cause

Tag mutability in container registries. OCI registries allow tags to be overwritten — a tag is just a pointer to a manifest digest, and that pointer can change at any time. Using a mutable tag in `FROM` means the build input is non-deterministic.

Contributing factors:
- Tutorials and quickstarts use `:latest` for simplicity
- Developers copy `FROM` lines without thinking about pinning
- No CI check for tag mutability
- Perceived inconvenience of updating digest pins (solved by Renovate/Dependabot)

---

## Vulnerable Dockerfile

```dockerfile
# vuln.Dockerfile — mutable :latest tag
FROM python:latest

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

EXPOSE 8080
CMD ["python", "app.py"]
```

---

## Detection — Vulnerable Image

### hadolint — catches :latest at Dockerfile level

```
lab02/vuln.Dockerfile:2 DL3007 warning: Using latest is prone to errors if the image
will ever update. Pin the version explicitly to a release tag
```

Unlike Lab 01 (missing USER), hadolint catches `:latest` cleanly because the string is explicit in the Dockerfile.

### dockle — CIS benchmark scan on built image

```
FATAL   - DKL-DI-0005: Clear apt-get caches
        * [dozens of packages in base image layers]
WARN    - CIS-DI-0001: Create a user for the container
        * Last user should not be root
WARN    - DKL-DI-0006: Avoid latest tag
        * Avoid 'latest' tag
INFO    - CIS-DI-0005: Enable Content trust for Docker
INFO    - CIS-DI-0006: Add HEALTHCHECK instruction to the container image
INFO    - CIS-DI-0008: Confirm safety of setuid/setgid files
        * setuid file: urwxr-xr-x usr/lib/openssh/ssh-keysign
        * setuid file: urwxr-xr-x usr/bin/passwd
        * [... 13 SUID/SGID binaries]
```

`DKL-DI-0006` confirms the latest tag. The massive `DKL-DI-0005` output shows dozens of packages installed across base image layers — all attack surface from `python:latest`.

### crane — record what :latest resolves to today

```bash
crane digest python:latest
```

```
sha256:ffebef43892dd36262fa2b042eddd3320d5510a21f8440dce0a650a3c124b51d
```

This digest will be different the next time the upstream maintainer pushes. There is no mechanism to detect or alert on that change.

---

## Vulnerability Proof — The Numbers

### Image size comparison

```
REPOSITORY   TAG       IMAGE ID       CREATED              SIZE
lab02-vuln   latest    74c2c484c1e9   About a minute ago   1.63GB
```

`python:latest` is the **full** Python image — it includes compilers, build tools, git, curl, wget, and hundreds of OS packages your Flask app never calls.

### Trivy scan — what you inherit silently

```
Total: 196 (HIGH: 196, CRITICAL: 0)
```

196 HIGH vulnerabilities inherited from `python:latest` with no awareness of which version was pulled. These CVEs exist in packages the application never uses.

---

## Fixed Dockerfile

```dockerfile
# fixed.Dockerfile — version tag + non-root user
FROM python:3.12-slim

WORKDIR /app

RUN groupadd --gid 1001 appgroup && \
    useradd --uid 1001 \
            --gid appgroup \
            --shell /bin/false \
            --no-create-home \
            appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY --chown=appuser:appgroup app.py .

USER appuser
EXPOSE 8080
CMD ["python", "app.py"]
```

### Getting the real digest for a full pin

```bash
crane digest python:3.12-slim
# sha256:3d5ed973e45820f5ba5e46bd065bd88b3a504ff0724d85980dcd05eab361fcf4
```

For production, use the digest directly in `FROM`:

```dockerfile
FROM python:3.12-slim@sha256:3d5ed973e45820f5ba5e46bd065bd88b3a504ff0724d85980dcd05eab361fcf4
```

### Keeping digest pins current with Renovate

Add `.renovaterc.json` to your repo:

```json
{
  "extends": ["config:base"],
  "dockerfile": {
    "enabled": true,
    "pinDigests": true
  }
}
```

Renovate opens a PR automatically when a new digest is available. You review, merge, pin stays current.

---

## Detection — Fixed Image

### dockle

```
FATAL   - DKL-DI-0005: Clear apt-get caches
WARN    - DKL-DI-0006: Avoid latest tag
INFO    - CIS-DI-0005: Enable Content trust for Docker
INFO    - CIS-DI-0006: Add HEALTHCHECK instruction to the container image
INFO    - CIS-DI-0008: Confirm safety of setuid/setgid files
        * [11 SUID/SGID binaries — reduced from 13]
```

> **Tool nuance:** `DKL-DI-0006` still appears on the fixed image. This is because our local image is tagged `lab02-fixed:latest` — dockle reads the image's own tag, not the base image tag in the Dockerfile. In a real pipeline where images are tagged with version numbers (`myapp:v1.2.3`), this warning disappears. This is not a regression — it is a labelling artefact of the lab environment.

Key improvements:
- `CIS-DI-0001` is **gone** — USER directive added from Lab 01 fix
- SUID binaries reduced from 13 to 11 — smaller base image has fewer pre-installed binaries

---

## Before / After Comparison

| Metric | Vulnerable (`python:latest`) | Fixed (`python:3.12-slim`) |
|--------|------------------------------|---------------------------|
| **Image size** | 1.63GB | 223MB |
| **HIGH CVEs** | 196 | 6 |
| **CRITICAL CVEs** | 0 | 0 |
| **Reproducible builds** | ❌ Tag is mutable | ✅ Tag is version-pinned |
| **Digest pinnable** | ❌ Changes without notice | ✅ `crane digest` gives pin |
| **`DKL-DI-0006`** | ⚠️ WARN | ✅ Resolved (in prod tagging) |
| **`CIS-DI-0001`** | ⚠️ WARN | ✅ Resolved |
| **SUID binaries** | 13 | 11 |

**196 → 6 HIGH CVEs** from switching base image alone — before touching a single line of application code.

