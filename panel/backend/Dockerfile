FROM python:3.12-slim
WORKDIR /app
RUN apt-get update -qq && apt-get install -y -q ca-certificates && update-ca-certificates && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY *.py .
ENV DATA_DIR=/data \
    TOML_PATH=/teleproxy/config.toml \
    EE_DOMAIN_RAW=""
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips=*"]
