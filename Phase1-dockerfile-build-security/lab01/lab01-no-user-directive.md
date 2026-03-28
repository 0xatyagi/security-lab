# Lab 01 — Dockerfile Without USER Directive

| Field | Value |
|-------|-------|
| **Risk Rating** | 🔴 High |
| **CIS Docker Benchmark** | 4.1 — Ensure a user for the container has been created |
| **MITRE ATT&CK** | T1611 — Escape to Host |
| **Tools Used** | `hadolint`, `dockle`, `trivy`, `docker inspect` |
| **CVE Reference** | CVE-2019-5736 (runc container escape — requires root in container) |
| **Lab Completed** | March 2026 |

---

## Overview

When a Dockerfile has no `USER` directive, the container process runs as **UID 0 — root**. This is Docker's default and it is a serious misconfiguration.

Root inside a container can:
- Read `/etc/shadow` (system password hashes)
- Install packages at runtime (`apt-get`)
- Write to system directories (`/etc/`, `/usr/local/bin/`)
- **Escape to the host** in specific kernel/runtime configurations

**CVE-2019-5736** demonstrated the real-world impact: a malicious container process running as root could overwrite the host `runc` binary through `/proc/self/exe`, achieving code execution on the host. The precondition was root inside the container — a non-root user stops this exploit entirely.

---

## Root Cause

The absence of a `USER` directive in the Dockerfile. Docker defaults to UID 0 when no user is specified. Most base images (`python`, `node`, `golang`) ship without creating a non-root user, so unless the author explicitly creates one, everything runs as root.

Contributing factors:
- Base images default to root
- Local development "just works" with root — no permission errors surface
- No CI gate checking for the USER directive
- Misconception that container isolation makes root safe

---

## Vulnerable Dockerfile

```dockerfile
# vuln.Dockerfile — NO USER directive
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8080
CMD ["python", "app.py"]
```

---

## Detection — Vulnerable Image

### hadolint (Dockerfile linter)

> **Tool Gap — documented:** hadolint `DL3002` fires when the last `USER` is explicitly set to `root`. When `USER` is absent entirely, hadolint 2.14.0 stays silent — it cannot confirm the final user *is* root without an explicit statement. Always pair hadolint with dockle for complete coverage.

```bash
# Confirm the gap
echo -e "FROM python:3.12-slim\nUSER root" | hadolint -
# DL3002 fires for explicit USER root

hadolint vuln.Dockerfile
# Silent — no USER directive present, hadolint cannot infer root
```

### dockle (CIS Benchmark scan on built image)

```
FATAL   - DKL-DI-0005: Clear apt-get caches
        * Use 'rm -rf /var/lib/apt/lists' after 'apt-get install|update'
WARN    - CIS-DI-0001: Create a user for the container
        * Last user should not be root
WARN    - DKL-DI-0006: Avoid latest tag
        * Avoid 'latest' tag
INFO    - CIS-DI-0005: Enable Content trust for Docker
INFO    - CIS-DI-0006: Add HEALTHCHECK instruction to the container image
INFO    - CIS-DI-0008: Confirm safety of setuid/setgid files
        * setuid file: urwxr-xr-x usr/bin/mount
        * setuid file: urwxr-xr-x usr/bin/su
        * setuid file: urwxr-xr-x usr/bin/passwd
        [... more SUID binaries]
```

**`CIS-DI-0001` is the key finding** — confirms the container runs as root.

### docker inspect

```
User: 
```

Empty string — Docker has no idea who is running this container. Defaults to root silently.

---

## Exploitation — Proof of Concept

All commands run as an unprivileged user who has gained `docker exec` access (simulating post-compromise lateral movement).

### Confirm root access

```
===== WHOAMI =====
root

===== ID =====
uid=0(root) gid=0(root) groups=0(root)
```

### Read sensitive system files

```
===== READ /etc/shadow =====
root:*:20528:0:99999:7:::
daemon:*:20528:0:99999:7:::
bin:*:20528:0:99999:7:::
sys:*:20528:0:99999:7:::
[... full /etc/shadow readable]
```

A non-root user would receive `Permission denied`.

### Overwrite application binary

```
===== OVERWRITE APP BINARY =====
SUCCESS - app binary overwritten
```

Root overwrote `/app/app.py` with `/bin/bash`. The application is now replaced.

> **Note on nmap install:** `python:3.12-slim` doesn't have nmap in its apt cache, so the install fails with "Unable to locate package." This is a base image limitation, not a security control — root had full permission to try. On a fuller base image (`ubuntu`, `debian`) the install would succeed. The install attempt returning a package error rather than a permission error is itself evidence of root access.

---

## Fixed Dockerfile

```dockerfile
# fixed.Dockerfile — dedicated non-root user
FROM python:3.12-slim

WORKDIR /app

# Create a dedicated non-root user with explicit UID/GID
RUN groupadd --gid 1001 appgroup && \
    useradd --uid 1001 \
            --gid appgroup \
            --shell /bin/false \
            --no-create-home \
            appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Set file ownership at copy time — no extra RUN chown layer needed
COPY --chown=appuser:appgroup . .

# Switch to non-root user for all subsequent instructions and runtime CMD
USER appuser

EXPOSE 8080
CMD ["python", "app.py"]
```

**Key changes:**
- `groupadd` and `useradd` create a dedicated user with explicit UID/GID `1001`
- `--shell /bin/false` prevents interactive login
- `--no-create-home` reduces filesystem footprint
- `COPY --chown=appuser:appgroup` sets ownership at copy time (no extra `RUN chown` layer)
- `USER appuser` switches to non-root for all subsequent instructions and the runtime CMD

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

**`CIS-DI-0001` is gone** — the primary finding is resolved.

Remaining findings are separate issues addressed in later labs:
- `DKL-DI-0005` — apt cache cleanup → Lab 04 (image bloat)
- `DKL-DI-0006` — latest tag → Lab 02
- `CIS-DI-0006` — missing HEALTHCHECK → Lab 07

### docker inspect

```
User: appuser
```

Docker now knows exactly who runs this container.

---

## Verification — Same Exploits, Fixed Image

```
===== WHOAMI =====
appuser

===== ID =====
uid=1001(appuser) gid=1001(appgroup) groups=1001(appgroup)

===== READ /etc/shadow =====
cat: /etc/shadow: Permission denied

===== INSTALL TOOLS =====
E: Could not open lock file /var/lib/dpkg/lock-frontend - open (13: Permission denied)
E: Unable to acquire the dpkg frontend lock (/var/lib/dpkg/lock-frontend), are you root?

===== CREATE FILE IN SYSTEM DIR =====
touch: cannot touch '/usr/local/bin/backdoor': Permission denied
BLOCKED - Permission denied

===== WRITE TO /etc/ =====
touch: cannot touch '/etc/crontab.evil': Permission denied
BLOCKED - Permission denied
```

---

## Before / After Comparison

| Attack Vector | Vulnerable (root) | Fixed (appuser) |
|---------------|-------------------|-----------------|
| `whoami` | `root` | `appuser` |
| UID | `uid=0` | `uid=1001` |
| Read `/etc/shadow` | ✅ Readable | ❌ Permission denied |
| Install packages | ✅ Permitted | ❌ Permission denied |
| Write to `/etc/` | ✅ Permitted | ❌ Permission denied |
| Write to `/usr/local/bin/` | ✅ Permitted | ❌ Permission denied |
| `docker inspect` User field | ` ` (empty) | `appuser` |
| `dockle` CIS-DI-0001 | ⚠️ WARN | ✅ Resolved |

---

## For Kubernetes — Enforce at Pod Level Too

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1001
  runAsGroup: 1001
```

This ensures Kubernetes rejects the pod if the container image tries to run as root — a defence-in-depth control on top of the Dockerfile fix.

---

## Interview Corner

**Q: Why isn't container isolation enough to make root safe?**
Container isolation relies on Linux namespaces and cgroups — kernel features. If there is a kernel vulnerability (CVE-2019-5736 in runc is the canonical example), a root process inside the container can break out of namespace isolation entirely. Running as non-root removes root from the exploit's precondition without requiring a kernel patch.

**Q: Why use a specific UID like 1001 instead of just a named user?**
In Kubernetes, multiple containers share a node and potentially shared volumes. Consistent UIDs across images ensure predictable file ownership. If two images both create a user named "appuser" but at different UIDs, they get unexpected access to each other's files on shared volumes. Explicit UIDs prevent accidental privilege overlap.

**Q: A developer says "we run behind a firewall, so root doesn't matter." How do you respond?**
The threat model for container root is not just external attackers — it is lateral movement after initial compromise. If an attacker compromises one service through an application vulnerability (SQL injection, RCE in a dependency), root in the container means they can install tools, access mounted volumes, modify application binaries, and potentially reach the host. The firewall protects the perimeter; it does not constrain what a compromised container can do internally. This is a code-level control, not an access control.

**Q: hadolint didn't catch the missing USER — does that make it useless?**
No — it means you need layered tooling. hadolint catches `DL3002` when `USER root` is explicit, catches many other Dockerfile anti-patterns (unpinned tags, ADD instead of COPY, missing --no-cache), and runs at pre-commit time before any image is built. dockle catches `CIS-DI-0001` on the built image. They complement each other. The lesson is: never rely on a single tool.

**Q: How does this finding appear in SAST tools in production?**
Checkov raises `CKV_DOCKER_8`, Trivy config raises it as a HIGH misconfiguration, hadolint raises `DL3002` for explicit root. The common developer rebuttal is "false positive — we trust our engineers." The counter: USER directive is not about trust, it is about least privilege. If the application doesn't need root to run (and Flask/Node/Go apps don't), it shouldn't have it.

---

## Cleanup

```bash
docker stop lab01-fixed-demo
docker rm lab01-fixed-demo
docker rmi lab01-vuln:latest lab01-fixed:latest
```

---

[← Phase 1 Overview](./README.md) | [Lab 02 →](./lab02-latest-untagged-images.md)