FROM redis:7.0.15-bookworm

ARG TARGETARCH
ARG AWS_CLI_VERSION=2.17.57

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        unzip; \
    \
    case "${TARGETARCH}" in \
        amd64) aws_arch="x86_64" ;; \
        arm64) aws_arch="aarch64" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    \
    curl -fsSL \
        "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}-${AWS_CLI_VERSION}.zip" \
        -o /tmp/awscliv2.zip; \
    \
    unzip -q /tmp/awscliv2.zip -d /tmp; \
    /tmp/aws/install; \
    \
    aws --version; \
    redis-cli --version; \
    \
    apt-get purge -y --auto-remove curl unzip; \
    apt-get clean; \
    rm -rf \
        /tmp/aws \
        /tmp/awscliv2.zip \
        /var/lib/apt/lists/*

USER 999:999

ENTRYPOINT ["/bin/bash", "/backup-script/backup.sh"]
