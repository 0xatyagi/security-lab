# Container Image Security — Hands-On Learning

A collection of hands-on container security labs I built while enhancing devsecops skills and deepening my knowledge of container security. Each lab has a vulnerable image, a working exploit, detection output from real tools, and a fixed version.

All commands were run on macOS with Docker Desktop. Evidence files in each lab folder contain real terminal output — not fabricated.

---

## What's in Here

| Phase | Topic | Labs |
|-------|-------|------|
| Phase 1 | Dockerfile and Build Security | Labs 01–09 |
| Phase 2 | Image Trust and Supply Chain | Labs 10–18 |
| Phase 3 | Image Hardening and Analysis | Labs 19–27 |
| Phase 4 | Admission Control and Pipelines | Labs 28–35 |

Phase 1 is complete. Phases 2–4 in progress.

---

## Phase 1 Findings — Dockerfile and Build Security

### Lab 01 — Running as Root (High)

No `USER` directive means the container process runs as UID 0. Proved this by reading `/etc/shadow`, attempting package installs, and overwriting the application binary — all from inside the container. Fix: create a dedicated non-root user with explicit UID/GID and switch to it before `CMD`.

### Lab 02 — Unpinned Base Image Tag (Medium)

`FROM python:latest` resolves to a different digest every time the upstream maintainer pushes. Used `crane digest` to capture the current digest, showed 196 HIGH CVEs inherited silently. Switching to `python:3.12-slim` dropped that to 6. For full reproducibility: pin to digest with `@sha256:...` and automate updates with Renovate.

### Lab 03 — Secrets Baked into Layers (Critical)

Passed a database password via `ARG` and copied a `.env` file, then ran `RUN rm -f .env` thinking it was cleaned up. `docker history --no-trunc` showed the full credential. `trufflehog` found the same credential in two independent locations: the file layer and the build history metadata. The `rm` does nothing — layers are append-only. Fix: BuildKit `--mount=type=secret` and a `.dockerignore`.

### Lab 04 — Bloated Image (Medium)

`FROM python:3.12` with build dependencies left in the final image: 1.63GB, 473 packages, 205 HIGH CVEs, and six post-exploitation tools (curl, wget, gcc, make, bash, apt-get) all pre-installed. Multi-stage build brought this to 215MB, 102 packages, 8 CVEs, zero attack tools.

### Lab 05 — No Vulnerability Scanning in Pipeline (High)

The Dockerfile looked clean — hadolint and dockle found nothing critical. But the image carried 11 CVEs that shipped silently because the pipeline had no scan gate. Added `trivy image --exit-code 1 --ignore-unfixed --severity HIGH,CRITICAL` between build and push. Key nuance: `--ignore-unfixed` is required, otherwise trivy returns exit code 0 on CVEs with no fix available and the gate never fires.

### Lab 06 — Build Cache Leaking Credentials (High)

Passed a private registry token via `ARG` and `ENV` in a multi-stage build. BuildKit caught it with `SecretsUsedInArgOrEnv` warnings on both lines — but still built the image. Modern BuildKit no longer stores ARG values in `docker history` (improvement from older versions), but the token still appears in CI build logs and cache export metadata. Fix: `--mount=type=secret`.

### Lab 07 — Missing HEALTHCHECK (Medium)

Without a `HEALTHCHECK`, Docker has no application-level awareness. A hung or crashing process still shows as "Up". Proved this with `docker inspect` returning `null` for health state. Added a `curl -f http://localhost:8080/health` check with appropriate interval and retries. After the start period, `docker ps` showed `Up 45 seconds (healthy)`.

### Lab 08 — ADD Instead of COPY (Medium)

`ADD` auto-extracts archives and fetches remote URLs with no checksum verification. Both are unintended behaviours for standard file copying. hadolint raised `DL3020` as an **error** (not a warning) on every `ADD` line. dockle raised `CIS-DI-0009` as FATAL. Fix: replace with `COPY`. For remote files: `curl` with `sha256sum -c` verification.

### Lab 09 — Unnecessary Port Exposure (Medium)

Dockerfile exposed four ports: 3000 (app), 9229 (Node.js debugger), 9090 (metrics), 8443 (admin). Running with `docker run -P` published all four to `0.0.0.0` on random high ports. Port 9229 (the Node.js inspector) allows arbitrary JavaScript execution via WebSocket — full RCE from a "development" port that nobody removed. Fix: expose only the production port. Never use `-P` in production.

---

## Tools Used

**hadolint** — Dockerfile linter. Runs on the file itself before any image is built. Catches syntax issues, unpinned tags (DL3007), ADD vs COPY (DL3020 as error), missing `--no-install-recommends`, unpinned apt versions. Fast enough to run as a pre-commit hook.

**dockle** — CIS Docker Benchmark checker. Runs against the built image. Checks runtime configuration: whether the container runs as non-root (CIS-DI-0001), whether HEALTHCHECK exists (CIS-DI-0006), credential detection in ENV (CIS-DI-0010), ADD vs COPY (CIS-DI-0009). Different from hadolint — it operates on the image, not the Dockerfile.

**trivy** — Primary vulnerability scanner. Scans OS packages and application dependencies in the built image. Also does Dockerfile misconfiguration scanning via `trivy config`. Used as the CI hard gate with `--exit-code 1 --ignore-unfixed --severity HIGH,CRITICAL`.

**grype** — Second vulnerability scanner for cross-validation. Uses a different database from trivy. Found CVEs that trivy classified differently in Lab 05. Running both takes 60 seconds and improves coverage.

**trufflehog** — Secret scanner. Scans every layer of an image for credential patterns. In Lab 03 it found the same credential in two places: the file layer and the build history metadata. Requires saving the image as a tar first for local images (`docker save`).

**crane** — OCI registry tool. Used to get the current digest of a tag (`crane digest python:3.12-slim`) for pinning, inspect manifests without pulling, and compare image sizes.

**dive** — Interactive layer explorer. Shows what each layer adds, modifies, or removes. Useful for spotting wasted space, misplaced files, and secrets that survived a `RUN rm`.

---

## Gaps Found in the Tools

These came up during the labs. Knowing what a tool misses is as useful as knowing what it catches.

**hadolint is silent when USER is absent** — `DL3002` fires when `USER root` is explicitly written. When there is no `USER` directive at all, hadolint says nothing. It cannot infer that the absence means root. Pair with dockle `CIS-DI-0001` which catches this on the built image.

**hadolint has no secret detection** — ARG or ENV with a credential value passes hadolint without any warning. It checks syntax, not values. Use trufflehog and dockle `CIS-DI-0010` for this.

**trivy --exit-code 1 does not block on unfixable CVEs** — If all HIGH CVEs have status `fix_deferred`, trivy returns exit code 0 even with `--exit-code 1`. Add `--ignore-unfixed` to focus the gate on CVEs that actually have patches available. Without this, the pipeline gate never fires on some images.

**grype --fail-on changed in v0.110.0** — grype logs `ERROR discovered vulnerabilities at or above the severity threshold` but returns exit code 0. The flag behaviour changed between versions. Check release notes for your specific version.

**trufflehog cannot scan local images directly (v3.94.x)** — `trufflehog docker --image myimage:latest` tries to pull from Docker Hub. Save the image first: `docker save myimage:latest -o /tmp/img.tar`, then `trufflehog docker --image=file:///tmp/img.tar`.

**dockle DKL-DI-0005 fires on base image layers** — The apt cache warning appears for layers inherited from the base image that are outside our control. It shows up on both vulnerable and fixed images. Treat as noise for `python:3.x-slim` base images unless it is from your own `RUN apt-get install` layer.

---

## Environment

- macOS, Docker Desktop
- hadolint 2.14.0
- dockle (latest)
- trivy (latest)
- grype 0.110.0
- trufflehog 3.94.x
- crane 0.21.3
