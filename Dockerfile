FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements-worker.txt ./requirements-worker.txt
RUN pip install --no-cache-dir -r requirements-worker.txt

COPY worker ./worker

CMD ["python", "worker/azure_ocr_worker.py", "--poll"]
