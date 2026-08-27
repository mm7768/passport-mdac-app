FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt ./
RUN pip install -r requirements.txt \
    && playwright install --with-deps chromium

COPY worker.py ./worker.py

CMD ["python", "worker.py", "--poll"]
