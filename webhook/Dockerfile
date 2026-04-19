FROM alpine:3.22

ARG WEBHOOK_VERSION=2.8.3

RUN apk add --no-cache git ca-certificates curl docker-cli-compose \
    && curl -fsSL "https://github.com/adnanh/webhook/releases/download/${WEBHOOK_VERSION}/webhook-linux-amd64.tar.gz" \
        | tar -xz -C /tmp \
    && mv /tmp/webhook-linux-amd64/webhook /usr/local/bin/webhook \
    && chmod +x /usr/local/bin/webhook \
    && rm -rf /tmp/webhook-linux-amd64

ENTRYPOINT ["webhook"]
