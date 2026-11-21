# syntax=docker/dockerfile:1
FROM python:3.12-slim-bookworm@sha256:935c3c5b12357a7e10caa9c1e6ca5692344d97cf229832ef584be2cec9fc03df AS model
ADD --checksum=sha256:30f26242c4eb449f948e42cb302dd7a686cb29a3423a8367f99ff41780942498 https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip /tmp/model.zip
RUN python -m zipfile -e /tmp/model.zip /models

FROM python:3.12-slim-bookworm@sha256:935c3c5b12357a7e10caa9c1e6ca5692344d97cf229832ef584be2cec9fc03df
RUN apt-get update \
    && apt-get install -y --no-install-recommends libatomic1 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY --from=model /models/vosk-model-small-en-us-0.15 /models/en-us
COPY server.py .
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 65532:65532
EXPOSE 8095
CMD ["python", "server.py"]
