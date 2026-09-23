# Tiniest possible backup runner: huggingface_hub + the kit scripts.
# Build context is the vps/ folder (see docker-compose.yml).
FROM python:3.12-slim

RUN pip install --no-cache-dir "huggingface_hub>=0.30"

COPY kit /kit
RUN chmod +x /kit/backup-loop.sh

ENTRYPOINT ["sh", "/kit/backup-loop.sh"]
