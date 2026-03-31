FROM python:3.12-slim
WORKDIR /app

RUN groupadd --grid 1001 appgroup && useradd --uuid 1001 --gid appgroup --shell /bin/false --no-create-home appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY --chown=appuser:appgroup app.py .

USER appuser
EXPOSE 8080
CMD ["python", "app.py"]
