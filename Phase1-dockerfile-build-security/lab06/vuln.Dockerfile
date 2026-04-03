# vuln.Dockerfile — secret passed as ARG, leaks into build cache metadata
FROM python:3.12-slim AS builder

WORKDIR /build

# BAD: Token passed as ARG — baked into cache metadata permanently
ARG PIP_TOKEN
ENV PRIVATE_REGISTRY_TOKEN=${PIP_TOKEN}

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