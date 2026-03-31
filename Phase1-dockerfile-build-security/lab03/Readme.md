# Lab 03 — Secrets Baked into Image Layers

| Field | Value |
|-------|-------|
| **Risk Rating** | 🔴 Critical |
| **CIS Docker Benchmark** | 4.10 — Ensure secrets are not stored in Dockerfiles |
| **MITRE ATT&CK** | T1552.001 — Unsecured Credentials: Credentials in Files |
| **Tools Used** | `docker history`, `docker inspect`, `dockle`, `trufflehog` |
| **trufflehog version** | 3.94.1 |
| **Lab Completed** | March 2026 |

---

## What Is This?

Every instruction in a Dockerfile creates a **layer**. Layers are immutable and additive. If you `COPY .env` into layer 5, then `RUN rm .env` in layer 6, **the `.env` file still exists in layer 5**. Anyone who pulls the image can extract every layer and read those secrets.

Secrets leak through two independent paths in this lab:

1. **`ARG` / `ENV` values** — visible in plain text via `docker history --no-trunc` and `docker inspect`, permanently baked into image metadata
2. **Copied secret files** — even after `RUN rm -f .env`, the layer containing the file is permanently part of the image manifest

`docker history --no-trunc` reveals `ARG` and `ENV` values in plain text. `trufflehog` scans image layers automatically for credential patterns. **If you push a secret into a layer, assume it is public.**

---

## Root Cause

Misunderstanding Docker's layer model. Each `RUN`, `COPY`, and `ADD` instruction creates a new filesystem layer. Deleting a file in a subsequent layer only adds a whiteout marker — the original file remains in the earlier layer and is fully readable.

Contributing factors:
- Developers treat Dockerfiles like shell scripts — copy, use, delete
- `ARG` and `ENV` values are recorded in image metadata
- No `.dockerignore` file, so `COPY .` grabs everything including `.env`
- Misconception that `RUN rm` removes secrets from the image

---

## Vulnerable Dockerfile

```dockerfile
# vuln.Dockerfile — secrets baked into image layers
FROM python:3.12-slim

WORKDIR /app

# BAD: Secret passed as build argument — visible in docker history
ARG DB_PASSWORD
ENV DATABASE_URL=postgres://admin:${DB_PASSWORD}@db.prod.internal:5432/app

# BAD: Copying .env file into the image
COPY .env ./

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

# "Cleanup" — this does NOT remove secrets from earlier layers
RUN rm -f .env

EXPOSE 8080
CMD ["python", "app.py"]
```

---

## Detection — Vulnerable Image

### hadolint — SILENT (tool gap documented)

```
(no output)
```

hadolint 2.14.0 has no rules for detecting secrets passed via `ARG` or `ENV`. Secret detection requires post-build tools. However, Docker's BuildKit does warn at build time:

```
SecretsUsedInArgOrEnv: Do not use ARG or ENV instructions for sensitive data (ARG "DB_PASSWORD")
```

BuildKit warns but does **not** block the build by default.

### dockle — catches credential in environment variables

```
FATAL   - CIS-DI-0010: Do not store credential in environment variables/files
        * Suspicious ENV key found : DB_PASSWORD on ARG DB_PASSWORD=*******
        * Suspicious ENV key found : DB_PASSWORD on RUN |1 DB_PASSWORD=******* /bin/sh -c pip install...
        * Suspicious ENV key found : DB_PASSWORD on RUN |1 DB_PASSWORD=******* /bin/sh -c rm -f .env
FATAL   - DKL-DI-0005: Clear apt-get caches
WARN    - CIS-DI-0001: Create a user for the container
WARN    - DKL-DI-0006: Avoid latest tag
```

`CIS-DI-0010` is a FATAL finding — credentials detected in environment variables. Note that dockle redacts the value with `*******` in its output, but the actual secret is readable via `docker history --no-trunc`.

---

## Exploitation — Three Independent Attack Paths

### Path 1 — docker history reveals ARG and ENV values in plain text

```
ARG DB_PASSWORD=s3cr3t@P@ssw0rd
ENV DATABASE_URL=postgres://admin:s3cr3t@P@ssw0rd@db.prod.internal:5432/app
```

Anyone who pulls the image and runs `docker history --no-trunc` gets the full database password. No special tools required.

### Path 2 — Prove rm -f does NOT protect the secret

```
===== PROVE .env SURVIVES rm -f (run container and check) =====
FILE NOT IN RUNNING CONTAINER (deleted by rm)

===== BUT SECRET IS IN LAYER HISTORY (rm did not protect it) =====
<missing>   COPY .env ./ # buildkit   12.3kB

===== AND SECRET IS IN ENV METADATA =====
DATABASE_URL=postgres://admin:s3cr3t@P@ssw0rd@db.prod.internal:5432/app
```

The `rm -f .env` succeeded in the running container — the file is gone from the container's view. But the layer containing it (`12.3kB`) is permanently baked into the image manifest. And independently, the `ENV DATABASE_URL` is readable via `docker inspect` regardless.

### Path 3 — trufflehog automated secret scanning

```
Found unverified result
Detector Type: Postgres
Raw result: postgres://admin:s3cretP@ssw0rd@db.prod.internal:5432
File: /app/.env
Layer: sha256:fa73ee1a594cd2afbd03bbeda29bd03d2d9f4b45431d48b33c5e175e5cc35f01

Found unverified result
Detector Type: Postgres
Raw result: postgres://admin:s3cr3t@P@ssw0rd@db.prod.internal:5432
File: image-metadata:history:12:created-by
```

Trufflehog found the same credential in **two independent locations**:
- `/app/.env` — the file layer (supposedly deleted by `rm -f`)
- `image-metadata:history:12` — the build history metadata from the `ARG`/`ENV` instructions

---

## Fixed Dockerfile

```dockerfile
# fixed.Dockerfile — no secrets in layers
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

Runtime secrets are injected via environment variables at container start — never baked into the image:

```bash
docker run -e DATABASE_URL=postgres://admin:password@db:5432/app lab03-fixed:latest
```

### Critical: always add .dockerignore

```
# .dockerignore
.env
*.env
*.pem
*.key
id_rsa
id_ed25519
.git
__pycache__
```

The `.dockerignore` prevents `COPY .` from grabbing secret files in the first place.

### For build-time secrets — use BuildKit secret mounts

```dockerfile
# Secret is mounted as tmpfs — never written to any layer
RUN --mount=type=secret,id=db_config \
    cat /run/secrets/db_config > /app/config.json
```

```bash
DOCKER_BUILDKIT=1 docker build \
  --secret id=db_config,src=./db_config.env \
  -t myapp:latest .
```

BuildKit mounts secrets as in-memory tmpfs that exists only during the `RUN` instruction — never written to any layer.

---

## Detection — Fixed Image

### dockle

```
FATAL   - DKL-DI-0005: Clear apt-get caches
WARN    - DKL-DI-0006: Avoid latest tag
INFO    - CIS-DI-0005: Enable Content trust for Docker
INFO    - CIS-DI-0006: Add HEALTHCHECK instruction to the container image
INFO    - CIS-DI-0008: Confirm safety of setuid/setgid files
```

**`CIS-DI-0010` is completely gone** — the critical secret finding is resolved.

### docker history — no application secrets

Only Python base image environment variables remain (`PYTHON_VERSION`, `GPG_KEY`, `LANG`, `PATH`). No `DB_PASSWORD`, no `DATABASE_URL`.

### docker inspect — no application secrets in env

```
PATH=/usr/local/bin:/usr/local/sbin:...
LANG=C.UTF-8
GPG_KEY=7169605F62C751356D054A26A821E680E5FA6305
PYTHON_VERSION=3.12.13
PYTHON_SHA256=c08bc65a81971c1dd5783182826503369466c7e67374d1646519adf05207b684
```

No application credentials anywhere in the metadata.

### trufflehog — 0 application secrets, 3 base image false positives

```
Found unverified result
Detector Type: URI
Raw result: http://username:password@host.com:80
File: /usr/local/lib/python3.12/site-packages/pip/_vendor/urllib3/util/url.py

Found unverified result
Detector Type: Box
Raw result: 4f8872954327c3e11544372df11503c0
File: /var/lib/dpkg/info/libc6:arm64.md5sums
```

All 3 remaining findings are base image false positives:
- `http://username:password@host.com:80` — a placeholder URL in pip's urllib3 source code, not a real credential
- `4f8872954327c3e11544372df11503c0` — an MD5 checksum in libc6 package metadata, not a secret

Our `DATABASE_URL` and `DB_PASSWORD` are completely absent from the fixed image.

---

## Before / After Comparison

| Check | Vulnerable | Fixed |
|-------|-----------|-------|
| `docker history` DB_PASSWORD | ✅ Visible in plain text | ❌ Not present |
| `docker history` DATABASE_URL | ✅ Visible in plain text | ❌ Not present |
| `docker inspect` env secrets | ✅ Full connection string | ❌ Not present |
| `.env` layer in image | ✅ 12.3kB layer exists | ❌ Not present |
| `rm -f .env` protects secret | ❌ No — layer persists | N/A |
| trufflehog Postgres findings | ✅ 2 real findings | ❌ 0 real findings |
| trufflehog remaining | — | 3 base image false positives |
| `CIS-DI-0010` dockle | 🔴 FATAL | ✅ Resolved |
| `CIS-DI-0001` dockle | ⚠️ WARN | ✅ Resolved |



## Cleanup

```bash
docker rmi lab03-vuln:latest lab03-fixed:latest
rm -f /tmp/lab03-vuln.tar /tmp/lab03-fixed.tar
rm -rf /tmp/lab03-extract
```

