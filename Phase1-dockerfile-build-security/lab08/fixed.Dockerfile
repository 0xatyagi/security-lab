# fixed.Dockerfile — using COPY instead of ADD
FROM python:3.12-slim

WORKDIR /app

RUN groupadd --gid 1001 appgroup && \
    useradd --uid 1001 --gid appgroup \
            --shell /bin/false --no-create-home appuser

# GOOD: COPY does exactly one thing — copies local files
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY --chown=appuser:appgroup app.py .

USER appuser
EXPOSE 8080
CMD ["python", "app.py"]