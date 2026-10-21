# unifi-cam-proxy for small ARM/x86 hosts (Raspberry Pi 4/5, any arm64 or amd64 Linux).
# Debian-based so ffmpeg and every Python dependency come as prebuilt packages/wheels: no
# Rust or C toolchain, builds on a Pi 4 in a few minutes. H.264 cameras only need -c:v copy;
# there is no hardware encoder here (a Pi cannot transcode to H.265 — see deploy/n100 for that).
FROM python:3.12-slim-bookworm
ENV PIP_NO_CACHE_DIR=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg netcat-openbsd ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
RUN pip install .
ENTRYPOINT ["unifi-cam-proxy"]
