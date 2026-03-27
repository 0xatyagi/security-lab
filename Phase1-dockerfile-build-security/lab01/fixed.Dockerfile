# fixed.Dockerfile — dedicated non-root user
FROM python:3.12-slim

WORKDIR /app

# Create a dedicated non-root user
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

# Switch to non-root user
USER appuser

EXPOSE 8080
CMD ["python", "app.py"]