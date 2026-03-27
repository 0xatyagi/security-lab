# Lab 01 — Dockerfile Without USER Directive

| Field | Value |
|-------|-------|
| **Risk Rating** | 🔴 High |
| **CIS Docker Benchmark** | 4.1 — Ensure a user for the container has been created |
| **MITRE ATT&CK** | T1611 — Escape to Host |
| **Tools** | `hadolint`, `dockle`, `docker inspect`, `trivy` |
| **CVE Reference** | CVE-2019-5736 (runc container escape — requires root in container) |
| **Time to Complete** | ~20 minutes |

---

## 📖 What Is This?

When a Dockerfile has no `USER` directive, the container process runs as **UID 0 — root**. This is Docker's default, and it's a significant security misconfiguration.

Root inside a container can:
- Read `/etc/shadow` (password hashes)
- Install packages via `apt-get` at runtime
- Modify application binaries on mounted volumes
- **Escape to the host** in specific kernel/runtime configurations

**CVE-2019-5736** demonstrated the real-world impact: a malicious container process running as root could overwrite the host `runc` binary through `/proc/self/exe`, achieving code execution on the host. The precondition was root inside the container — a non-root user stops this exploit entirely.

---

## 🏗️ Vulnerable Configuration

Create this Dockerfile:

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

Create a minimal `requirements.txt` and `app.py` for the build to succeed:

```bash
# requirements.txt
flask==3.0.0
```

```python
# app.py
from flask import Flask
app = Flask(__name__)

@app.route('/health')
def health():
    return 'ok'

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
```

Build and run:

```bash
docker build -f vuln.Dockerfile -t vuln-root-app .
docker run -d --name root-demo -p 8080:8080 vuln-root-app
```

---

## 🔍 Manual Exploitation

### Step 1 — Confirm we are root

```bash
docker exec root-demo whoami
# Expected: root

docker exec root-demo id
# Expected: uid=0(root) gid=0(root) groups=0(root)
```

### Step 2 — Read sensitive system files

```bash
docker exec root-demo cat /etc/shadow
# Expected: root:*:19750:0:99999:7::: daemon:*:19750:0:99999:7:::
# A non-root user would get: cat: /etc/shadow: Permission denied
```

### Step 3 — Install arbitrary tools at runtime

```bash
docker exec root-demo apt-get update -qq
docker exec root-demo apt-get install -y nmap netcat-openbsd
docker exec root-demo nmap --version
# Root can install reconnaissance and lateral movement tools at runtime
# This turns the container into an attack platform
```

### Step 4 — Modify application binaries

```bash
docker exec root-demo cp /bin/bash /app/app.py
# Root can overwrite the application with anything
# No file ownership protects against UID 0
```

### Step 5 — Inspect with docker inspect

```bash
docker inspect root-demo --format='{{.Config.User}}'
# Expected: (empty string) — no user configured
```

---

## 🕵️ Detection

### hadolint — catches missing USER at build time

```bash
hadolint vuln.Dockerfile
# Expected:
# vuln.Dockerfile:1 DL3002 warning: Last USER should not be root
```

> hadolint flags `DL3002` when the last USER is root or when no USER exists at all.

### dockle — CIS benchmark check on the built image

```bash
dockle vuln-root-app
# Expected:
# WARN - CIS-DI-0001: Create a user for the container
#        Last user should not be root
```

### docker inspect — runtime verification

```bash
docker inspect vuln-root-app --format='{{.Config.User}}'
# Returns empty string if no user is set
```

### trivy — misconfiguration scan on the Dockerfile

```bash
trivy config --severity HIGH,CRITICAL vuln.Dockerfile
# Flags the missing USER directive as a misconfiguration
```

---

## ✅ Solution — Fixed Dockerfile

```dockerfile
# fixed.Dockerfile — with dedicated non-root user
FROM python:3.12-slim

WORKDIR /app

# Create a dedicated non-root user with a specific UID/GID
RUN groupadd --gid 1001 appgroup && \
    useradd --uid 1001 --gid appgroup --shell /bin/false --no-create-home appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Set ownership at copy time — no extra RUN chown layer needed
COPY --chown=appuser:appgroup . .

# Switch to non-root for all subsequent instructions and the runtime CMD
USER appuser

EXPOSE 8080
CMD ["python", "app.py"]
```

**Key changes:**
- `groupadd` and `useradd` create a dedicated user with a specific UID/GID (1001)
- `--shell /bin/false` prevents interactive login
- `COPY --chown=appuser:appgroup` sets file ownership at copy time (no extra RUN chown layer)
- `USER appuser` switches to non-root for all subsequent instructions and the runtime CMD

**For Kubernetes, enforce this at the pod level too:**

```yaml
# Kubernetes pod security context
securityContext:
  runAsNonRoot: true
  runAsUser: 1001
  runAsGroup: 1001
```

---

## ✔️ Verification

```bash
# Build and run the fixed image
docker build -f fixed.Dockerfile -t fixed-root-app .
docker run -d --name fixed-demo -p 8081:8080 fixed-root-app

# Verify non-root user
docker exec fixed-demo whoami
# Expected: appuser

# Verify /etc/shadow is inaccessible
docker exec fixed-demo cat /etc/shadow
# Expected: cat: /etc/shadow: Permission denied

# Verify docker inspect shows the user
docker inspect fixed-root-app --format='{{.Config.User}}'
# Expected: appuser

# Verify hadolint passes
hadolint fixed.Dockerfile
# Expected: (no DL3002 warning)

# Verify dockle passes
dockle fixed-root-app
# Expected: CIS-DI-0001 no longer flagged
```

---

## 🧹 Cleanup

```bash
docker stop root-demo fixed-demo
docker rm root-demo fixed-demo
docker rmi vuln-root-app fixed-root-app
```

---

## 💡 Interview Corner

**Q: Why isn't container isolation enough to make root safe?**
> Container isolation relies on Linux namespaces and cgroups. These are kernel features. If there's a kernel vulnerability (like CVE-2019-5736 in runc), a root process inside the container can break out of the namespace isolation entirely. Running as non-root doesn't fix kernel bugs, but it removes root from the exploit's precondition.

**Q: Why use a specific UID like 1001 instead of a named user?**
> In Kubernetes environments, multiple containers may share a node and a mounted volume. Using consistent UIDs across images ensures predictable file ownership. If one image creates user "appuser" as UID 1000 and another also uses UID 1000 for a different service, they'll have access to each other's files on shared volumes. Explicit UIDs prevent accidental privilege overlap.

**Q: A developer says "we run behind a firewall, so root doesn't matter." How do you respond?**
> The threat model for container root isn't just external attackers — it's also lateral movement after initial compromise. If an attacker compromises one service through an application vulnerability, root in the container means they can install tools, access other containers' mounted volumes, and potentially reach the host. The firewall protects the perimeter; it doesn't constrain what a compromised container can do internally.

**Q: How does this finding appear in SAST tools?**
> SAST tools like Checkov, Trivy config, and Semgrep flag missing USER directives as misconfigurations. `hadolint` specifically raises `DL3002`. The common developer rebuttal is "false positive because we trust our engineers" — but USER directive is a code-level control, not an access control, and it doesn't depend on who runs the container.

---

[← Phase 1 Overview](./README.md) | [Lab 02 →](./lab02-latest-untagged-images.md)
