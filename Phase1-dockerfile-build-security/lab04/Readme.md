Lab 04 — Bloated Images with Unnecessary Packages
FieldValueRisk Rating🟡 MediumCIS Docker Benchmark4.3 — Ensure unnecessary packages are not installed in the containerMITRE ATT&CKT1059 — Command and Scripting InterpreterTools Usedhadolint, dockle, trivy, docker inspectLab CompletedMarch 2026

What Is This?
A full python:3.12 base image ships with hundreds of packages your application never calls. Each package is attack surface. System shells, package managers, compilers, network tools like curl, wget — these are the first things an attacker reaches for after gaining code execution in a container.
Post-exploitation in containers routinely depends on tools that come pre-installed in bloated images:

apt-get to install more tools
curl / wget to exfiltrate data or download payloads
gcc / make to compile exploit code inside the container
bash for interactive shells

Strip those out and the attacker has to bring their own tooling — which is harder, noisier, and more likely to be detected.

Root Cause
Using general-purpose OS images as application bases. These images are designed for interactive use with full development environments, not for running a single application process in production.
Contributing factors:

Convenience — FROM python:3.12 "just works" with familiar tools
Build dependencies conflated with runtime dependencies
No multi-stage build separating build tools from final image
Assumption that "slim" variants will break things


Vulnerable Dockerfile
dockerfile# vuln.Dockerfile — single stage, full image, build deps shipped to production
FROM python:3.12

WORKDIR /app

# Build dependencies installed and left in the final image
RUN apt-get update && apt-get install -y \
    build-essential \
    libpq-dev \
    gcc \
    make \
    curl \
    wget \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY app.py .

EXPOSE 8080
CMD ["python", "app.py"]

Detection — Vulnerable Image
hadolint
lab04/vuln.Dockerfile:7 DL3008 warning: Pin versions in apt-get install.
lab04/vuln.Dockerfile:7 DL3015 info: Avoid additional packages by specifying --no-install-recommends
lab04/vuln.Dockerfile:17 DL3042 warning: Avoid use of cache directory with pip. Use pip install --no-cache-dir
Three findings on the vulnerable Dockerfile — unpinned apt versions, missing --no-install-recommends, and pip cache not disabled. hadolint catches build hygiene issues but cannot measure the resulting attack surface.
dockle — vulnerable image
FATAL   - DKL-DI-0005: Clear apt-get caches
        * [4 separate base image apt-get install layers — autoconf, automake, bzip2, gcc,
          imagemagick, libssl-dev, git, mercurial, openssh-client, curl, wget, gnupg, and more]
WARN    - CIS-DI-0001: Create a user for the container
WARN    - DKL-DI-0006: Avoid latest tag
INFO    - CIS-DI-0008: Confirm safety of setuid/setgid files
        * 13 SUID/SGID binaries including ssh-keysign, ssh-agent
The massive DKL-DI-0005 output tells the story — four separate base image apt-get install layers with dozens of packages each.

Exploitation — Proof of Concept
Image size
REPOSITORY   TAG       IMAGE ID       CREATED          SIZE
lab04-vuln   latest    acb826e2e823   32 seconds ago   1.63GB
1.63GB for a Flask app that serves one endpoint. The application code is under 1KB.
Attack tools available to an attacker
/usr/bin/curl
/usr/bin/wget
/usr/bin/gcc
/usr/bin/make
/usr/bin/bash
/usr/bin/apt-get
Every tool an attacker needs for post-exploitation is pre-installed:

curl / wget — download payloads, exfiltrate data
gcc / make — compile exploit code inside the container
bash — interactive shell
apt-get — install anything else needed

Installed package count
473 packages installed
The application needs approximately 20 of them.
Vulnerability scan
Total: 205 (HIGH: 205, CRITICAL: 0)
205 HIGH CVEs — the majority in packages the Flask application never calls.

Fixed Dockerfile — Multi-Stage Build
dockerfile# fixed.Dockerfile — multi-stage build, minimal runtime image
FROM python:3.12-slim AS builder

WORKDIR /app

RUN apt-get update && apt-get install -y \
    --no-install-recommends \
    build-essential \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---- Runtime stage — minimal final image ----
FROM python:3.12-slim

WORKDIR /app

RUN apt-get update && apt-get install -y \
    --no-install-recommends \
    libpq5 \
    && apt-get purge -y --auto-remove \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /install /usr/local

RUN groupadd --gid 1001 appgroup && \
    useradd --uid 1001 \
            --gid appgroup \
            --shell /bin/false \
            --no-create-home \
            appuser

COPY --chown=appuser:appgroup app.py .

USER appuser
EXPOSE 8080
CMD ["python", "app.py"]
Key changes:

Builder stage uses python:3.12-slim with build dependencies — compiles packages
pip install --prefix=/install installs packages to a separate directory
Final stage uses python:3.12-slim — only the runtime library (libpq5), not the dev headers (libpq-dev)
COPY --from=builder /install /usr/local copies only compiled packages — no build tools
Non-root user added (fixes Lab 01 finding simultaneously)


Detection — Fixed Image
hadolint
lab04/fixed.Dockerfile:6 DL3008 warning: Pin versions in apt-get install.
lab04/fixed.Dockerfile:20 DL3008 warning: Pin versions in apt-get install.
Only unpinned apt versions remain — a minor finding. No DL3015 or DL3042.
dockle — fixed image
FATAL   - DKL-DI-0005: Clear apt-get caches
        * [1 base image layer — only ca-certificates, netbase, tzdata]
WARN    - DKL-DI-0006: Avoid latest tag
INFO    - CIS-DI-0005: Enable Content trust for Docker
INFO    - CIS-DI-0006: Add HEALTHCHECK instruction to the container image
INFO    - CIS-DI-0008: Confirm safety of setuid/setgid files
        * 11 SUID/SGID binaries
Key improvements:

CIS-DI-0001 gone — USER directive added
DKL-DI-0005 reduced from 4 base image layers to 1 — dramatically smaller package footprint
SUID binaries reduced from 13 to 11 — ssh-keysign and ssh-agent gone (openssh not in slim)


Verification — Fixed Image
Image size
REPOSITORY    TAG       IMAGE ID       CREATED          SIZE
lab04-fixed   latest    0f651eb78ca1   21 seconds ago   215MB
Attack tools — all missing
(no output — none of the tools exist in the image)
Installed package count
102 packages
Vulnerability scan
Total: 8 (HIGH: 8, CRITICAL: 0)
Cannot install tools
E: Could not open lock file /var/lib/dpkg/lock-frontend - open (13: Permission denied)
E: Unable to acquire the dpkg frontend lock (/var/lib/dpkg/lock-frontend), are you root?
Running as appuser (uid=1001) — cannot install anything.

Before / After Comparison
MetricVulnerable (python:3.12)Fixed (python:3.12-slim multi-stage)Image size1.63GB215MBInstalled packages473102HIGH CVEs2058CRITICAL CVEs00curl / wget✅ Present❌ Not presentgcc / make✅ Present❌ Not presentbash✅ Present❌ Not presentapt-get usable✅ Yes (root)❌ Permission deniedSUID binaries1311CIS-DI-0001⚠️ WARN✅ ResolvedDKL-DI-0005 layers4 base layers1 base layer
205 → 8 HIGH CVEs from switching base image and adding multi-stage build.