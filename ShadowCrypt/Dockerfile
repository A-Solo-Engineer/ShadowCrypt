# ============================================================================
# ShadowCrypt BlindRelay - Multi-Stage Production Dockerfile
# ============================================================================
# Stage 1: Builder - Compile Go binary with all security flags
# Stage 2: Runner - Minimal distroless image with zero attack surface
# ============================================================================

# Stage 1: Build Stage
FROM golang:1.21-alpine AS builder

# Install build dependencies
RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /build

# Copy go mod files
COPY go.mod go.sum ./

# Download dependencies (cached layer)
RUN go mod download

# Copy source code
COPY . .

# Build with security hardening flags
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-s -w \
    -X main.BuildVersion=$(git describe --tags --always --dirty 2>/dev/null || echo 'dev') \
    -X main.BuildCommit=$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown') \
    -X main.BuildTime=$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    -a -installsuffix cgo \
    -o /build/blindrelay \
    ./cmd/blindrelay/main.go

# Verify binary was created and is stripped
RUN ls -lh /build/blindrelay && file /build/blindrelay

# ============================================================================
# Stage 2: Runtime - Distroless Base Image
# ============================================================================
# gcr.io/distroless/static-debian12 includes:
# - libc, libstdc++
# - ca-certificates for HTTPS/TLS
# - tzdata for timezone support
# - NO shell, package manager, or unnecessary userland utilities
# Attack surface is minimal

FROM gcr.io/distroless/static-debian12:nonroot

# Metadata
LABEL org.opencontainers.image.title="ShadowCrypt BlindRelay"
LABEL org.opencontainers.image.description="Zero-knowledge message relay for encrypted messaging"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.vendor="ShadowCrypt"

# Copy timezone data from builder
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo

# Copy ca-certificates from builder for HTTPS validation
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy the compiled binary (nonroot user: UID 65532)
COPY --from=builder --chown=65532:65532 /build/blindrelay /app/blindrelay

# Set working directory
WORKDIR /app

# Expose port (Koyeb will inject $PORT via environment)
EXPOSE 3000

# Health check endpoints for Koyeb orchestration
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD ["/app/blindrelay", "-health-check"]

# Run as nonroot user (uid: 65532)
USER nonroot:nonroot

# Entry point - run the relay server
ENTRYPOINT ["/app/blindrelay"]

# Default arguments (can be overridden via docker run or Koyeb config)
CMD []

# ============================================================================
# SECURITY NOTES
# ============================================================================
# 1. Distroless image: No shell, no package manager - minimal attack surface
# 2. Nonroot user: Container runs as UID 65532 (nonroot), not root
# 3. Read-only filesystem: Koyeb can set securityContext.readOnlyRootFilesystem=true
# 4. Security context in Koyeb:
#    - runAsNonRoot: true
#    - runAsUser: 65532
#    - readOnlyRootFilesystem: true
#    - allowPrivilegeEscalation: false
#    - capabilities: drop all
# 5. Binary is stripped: No debug symbols, smaller image
# 6. Build-time flags: -s -w removes symbols, -a forces rebuild, -installsuffix isolates
# ============================================================================
