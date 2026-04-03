# fixed.Dockerfile — no secrets in ARG or ENV
# Runtime secrets injected via environment variables at container start
FROM python:3.12-slim AS builder

WORKDIR /build

# GOOD: No secret in ARG or ENV
# Build-time credentials would use: --mount=type=secret,id=pip_token
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt --prefix=/install

FROM python:3.12-slim

WORKDIR /app
COPY --from=builder /install /usr/local

RUN groupadd --gid 1001 appgroup && \
    useradd --uid 1001 --gid appgroup \
            --shell /bin/false --no-create-home appuser

COPY --chown=appuser:appgroup app.py .
USER appuser
EXPOSE 8080
CMD ["python", "app.py"]