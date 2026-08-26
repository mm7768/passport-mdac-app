FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY services/mdac-dry-run/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY services/mdac-dry-run/worker.py ./worker.py

CMD ["python", "worker.py"]
