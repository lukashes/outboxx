FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy exporter script
COPY kafka_exporter.py .

# Expose Prometheus metrics port
EXPOSE 8000

# Run exporter
CMD ["python", "-u", "kafka_exporter.py"]
