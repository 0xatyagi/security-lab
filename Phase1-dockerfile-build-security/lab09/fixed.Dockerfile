# fixed.Dockerfile — only expose production application port
FROM node:20-slim

WORKDIR /app

RUN groupadd --gid 1001 appgroup && \
    useradd --uid 1001 --gid appgroup \
            --shell /bin/false --no-create-home appuser

COPY --chown=appuser:appgroup app.py .

USER appuser

# Only the application port — no debug, metrics, or admin ports
EXPOSE 3000