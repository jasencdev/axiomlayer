# Build stage
FROM node:22-alpine AS builder

WORKDIR /app

# Install dependencies first (better layer caching)
COPY package*.json ./
RUN npm ci --only=production

# Copy source
COPY src/ ./src/

# Production stage
FROM node:22-alpine AS production

# Security: run as non-root
RUN addgroup -g 1000 app && \
    adduser -u 1000 -G app -s /bin/sh -D app

WORKDIR /app

# Copy from builder
COPY --from=builder --chown=app:app /app/node_modules ./node_modules
COPY --from=builder --chown=app:app /app/src ./src
COPY --chown=app:app package*.json ./

USER app

EXPOSE {{PORT}}

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:{{PORT}}/health || exit 1

CMD ["node", "src/index.js"]
