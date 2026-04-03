# vuln.Dockerfile — using ADD instead of COPY
FROM python:3.12-slim

WORKDIR /app

RUN groupadd --gid 1001 appgroup && \
    useradd --uid 1001 --gid appgroup \
            --shell /bin/false --no-create-home appuser

# BAD: ADD auto-extracts archives and fetches remote URLs
ADD requirements.txt .
ADD app.py .

USER appuser
EXPOSE 8080
CMD ["python", "app.py"]