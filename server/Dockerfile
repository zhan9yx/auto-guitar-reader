FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    AGR_DATA_DIR=/data

WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

RUN useradd --system --uid 10001 agr && mkdir -p /data && chown agr /data
USER agr
VOLUME /data
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s CMD python -c "import urllib.request,sys; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2)" || exit 1

# Single worker: SQLite (WAL) handles concurrent readers; scale vertically or put a proxy in front.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
