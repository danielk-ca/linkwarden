# ---------- Stage 1: Download monolith ----------
FROM debian:bullseye-slim AS monolith-builder

RUN apt-get update && apt-get install -y curl ca-certificates && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    arch=$(dpkg --print-architecture); \
    if [ "$arch" = "amd64" ]; then \
        url="https://github.com/Y2Z/monolith/releases/latest/download/monolith-linux-amd64"; \
    elif [ "$arch" = "arm64" ]; then \
        url="https://github.com/Y2Z/monolith/releases/latest/download/monolith-linux-arm64"; \
    else \
        echo "Unsupported architecture: $arch"; exit 1; \
    fi; \
    curl -L "$url" -o /usr/local/bin/monolith; \
    chmod +x /usr/local/bin/monolith


# ---------- Stage 2: Build Linkwarden ----------
FROM node:22-bullseye-slim

ENV YARN_HTTP_TIMEOUT=10000000
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
ENV PRISMA_HIDE_UPDATE_MESSAGE=1
ENV NODE_OPTIONS="--max-old-space-size=1024"

WORKDIR /opt/linkwarden

# Install system dependencies required by playwright
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    jq \
    git \
    && rm -rf /var/lib/apt/lists/*

# Enable Corepack
RUN corepack enable

# Copy project files
COPY . .

# Detect Yarn version from package.json (same logic as Proxmox script)
RUN set -eux; \
    yarn_ver="4.12.0"; \
    if [ -f package.json ]; then \
        pkg_manager=$(jq -r '.packageManager // empty' package.json || true); \
        if [ -n "$pkg_manager" ] && echo "$pkg_manager" | grep -q "^yarn@"; then \
            yarn_spec=${pkg_manager#yarn@}; \
            yarn_ver=${yarn_spec%%+*}; \
        fi; \
    fi; \
    corepack prepare "yarn@${yarn_ver}" --activate

# Install dependencies
RUN yarn workspaces focus linkwarden @linkwarden/web @linkwarden/worker

# Install playwright dependencies (required by Linkwarden)
RUN npx playwright install-deps
RUN npx playwright install

# Copy monolith binary
COPY --from=monolith-builder /usr/local/bin/monolith /usr/local/bin/monolith

# Build application
RUN yarn prisma:generate
RUN yarn web:build

# Clean caches (same cleanup logic used in script)
RUN rm -rf \
    ~/.cargo/registry \
    ~/.cargo/git \
    ~/.cargo/.package-cache \
    /root/.cache/yarn \
    /opt/linkwarden/.next/cache

HEALTHCHECK --interval=30s \
            --timeout=5s \
            --start-period=10s \
            --retries=3 \
            CMD curl --silent --fail http://127.0.0.1:3000/ || exit 1

EXPOSE 3000

CMD ["sh", "-c", "yarn prisma:deploy && yarn concurrently:start"]