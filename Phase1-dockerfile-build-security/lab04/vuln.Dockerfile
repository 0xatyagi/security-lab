# vuln.Dockerfile — single stage, full image, build deps shipped to production
FROM python:3.12

WORKDIR /app

# Build dependencies installed and left in the final image
RUN apt-get update && apt-get install -y \
    build-essential \
    libpq-dev \
    gcc \
    make \
    curl \
    wget \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY app.py .

EXPOSE 8080
CMD ["python", "app.py"]