# Grafana Alloy with the Kong → Grafana Cloud config baked in (no bind mount needed, works on Coolify).
ARG ALLOY_IMAGE=grafana/alloy:latest
FROM ${ALLOY_IMAGE}
COPY config.alloy /etc/alloy/config.alloy
