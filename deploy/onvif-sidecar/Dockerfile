# ONVIF event sidecar: the camera's own person/vehicle/animal detections -> proxy --ai-sink-port.
# Build context is deploy/ (see deploy/onvif/docker-compose.yml); the script lives in deploy/macos.
FROM python:3.12-alpine
RUN pip install --no-cache-dir aiohttp
WORKDIR /app
COPY macos/onvif_sidecar.py /app/onvif_sidecar.py
ENTRYPOINT ["python", "/app/onvif_sidecar.py"]
