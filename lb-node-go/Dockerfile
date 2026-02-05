# -------------------------
# Stage 1: Build the Go binary
# -------------------------
FROM golang:1.24-alpine AS builder

# Install git for module fetching and ca-certificates for HTTPS
RUN apk add --no-cache git ca-certificates

# Set working directory
WORKDIR /app

# Copy go.mod and go.sum first for better caching
COPY go.mod go.sum ./

# Download dependencies
RUN go mod download

# Copy the source code
COPY main.go ./

# Build a static binary
RUN CGO_ENABLED=0 GOOS=linux go build -o lb-node-go main.go

# -------------------------
# Stage 2: Minimal runtime image
# -------------------------
FROM alpine:3.18

# Install runtime dependencies
RUN apk add --no-cache haproxy bash curl jq ca-certificates

# Create app directory
WORKDIR /app

# Copy the Go binary from builder
COPY --from=builder /app/lb-node-go .

# Expose ports
EXPOSE 80 8404

# Set entrypoint
ENTRYPOINT ["/app/lb-node-go"]
