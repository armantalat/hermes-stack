# OmniRouter (keyless free web models) — built for the VM's own architecture.
# The upstream HF Dockerfile hardcodes linux-amd64, which breaks on ARM VMs
# (Oracle Always Free = Ampere ARM). This one picks amd64 or arm64 automatically.
FROM debian:bookworm-slim

ARG TARGETARCH
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) A=amd64 ;; \
      arm64) A=arm64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    echo "building for linux-${A}"; \
    curl -fsSL --retry 3 --retry-all-errors -o /tmp/omni.tar.gz \
      "https://github.com/Godde3s/omnirouter/releases/latest/download/dist-omnirouter-linux-${A}.tar.gz"; \
    tar -xzf /tmp/omni.tar.gz -C /app; \
    chmod +x /app/*linux-${A}; \
    ln -sf "/app/omnirouter-linux-${A}" /app/omnirouter; \
    ln -sf "/app/qwen-bx-linux-${A}" /app/qwen-bx; \
    rm -f /tmp/omni.tar.gz

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/app/entrypoint.sh"]
