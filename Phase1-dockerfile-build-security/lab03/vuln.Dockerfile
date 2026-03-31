# vuln.Dockerfile — secrets baked into image layers
FROM python:3.12-slim

WORKDIR /app

# BAD: Secret passed as build argument — visible in docker history
ARG DB_PASSWORD
ENV DATABASE_URL=postgres://admin:${DB_PASSWORD}@db.prod.internal:5432/app

# BAD: Copying .env file into the image
COPY .env ./

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

# "Cleanup" — this does NOT remove secrets from earlier layers
RUN rm -f .env

EXPOSE 8080
CMD ["python", "app.py"]