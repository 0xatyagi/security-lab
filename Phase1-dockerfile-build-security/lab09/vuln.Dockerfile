# vuln.Dockerfile — over-exposed ports including debug port
FROM node:20-slim

WORKDIR /app

RUN groupadd --gid 1001 appgroup && \
    useradd --uid 1001 --gid appgroup \
            --shell /bin/false --no-create-home appuser

COPY --chown=appuser:appgroup app.py .

USER appuser

# Application port
EXPOSE 3000

# DEBUG PORT — remote code execution via Node.js inspector
EXPOSE 9229

# Metrics/profiler port — leaks internal application data
EXPOSE 9090

# Admin interface
EXPOSE 8443