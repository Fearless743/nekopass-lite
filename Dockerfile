# syntax=docker/dockerfile:1.7

# Build the Vue frontend.
FROM --platform=$BUILDPLATFORM node:22-bookworm-slim AS web
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
COPY third_party/picomatch /src/third_party/picomatch
RUN npm ci --no-audit --no-fund
COPY web/ ./
RUN npm run build

# Build the control panel binary.
FROM --platform=$BUILDPLATFORM golang:1.26-bookworm AS build
WORKDIR /src
ENV CGO_ENABLED=0
# third_party/quic-go is a local module replacement and is required by go mod download.
COPY go.mod go.sum ./
COPY third_party/quic-go ./third_party/quic-go
RUN go mod download
COPY . .
ARG TARGETOS TARGETARCH
ARG VERSION=dev
RUN GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH:-$(go env GOARCH)} go build -trimpath \
    -ldflags "-s -w -X github.com/nekopass/nekopass/internal/release.Version=${VERSION}" \
    -o /out/nekopass ./cmd/nekopass

# Caddy binary for the bundled reverse proxy (single container, single port).
FROM caddy:2.10-alpine AS caddy

# Minimal runtime image. Caddy terminates TLS for both the panel (8080) and the
# agent control endpoint (9443) and routes by HTTP/2 path on one port.
FROM alpine:3.22
RUN apk add --no-cache ca-certificates tzdata bash \
    && addgroup -S -g 10001 nekopass \
    && adduser -S -u 10001 -G nekopass -h /var/lib/nekopass -s /bin/bash nekopass \
    && mkdir -p /opt/nekopass/bin /opt/nekopass/web /var/lib/nekopass /etc/caddy /data /config \
    && chown -R nekopass:nekopass /var/lib/nekopass /data /config
COPY --from=build /out/nekopass /opt/nekopass/bin/nekopass
COPY --from=web /src/web/dist/ /opt/nekopass/web/
COPY --from=caddy /usr/bin/caddy /usr/bin/caddy
COPY deploy/docker/Caddyfile /etc/caddy/Caddyfile
COPY deploy/docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

ENV NEKOPASS_PANEL_UPDATE_DIR=/var/lib/nekopass
ENV NEKOPASS_HTTP_ADDR=127.0.0.1:8080
ENV NEKOPASS_GRPC_ADDR=127.0.0.1:9443
ENV NEKOPASS_UPSTREAM=127.0.0.1:8080
ENV NEKOPASS_AGENT_UPSTREAM=127.0.0.1:9443
ENV NEKOPASS_TRUSTED_PROXIES=127.0.0.0/8

EXPOSE 80
WORKDIR /var/lib/nekopass
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
