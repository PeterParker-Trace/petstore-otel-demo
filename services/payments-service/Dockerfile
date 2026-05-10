# Multi-stage build.
FROM golang:1.22-alpine AS builder

WORKDIR /build

# Install git (required by go mod for some deps) and ca-certificates.
RUN apk add --no-cache git ca-certificates

# Copy module files and download deps. This layer is cached unless go.mod/sum change.
COPY go.mod ./
# go.sum doesn't exist yet on first build — we'll let `go mod tidy` create it.

COPY *.go ./

# `go mod tidy` resolves transitive dependencies and creates go.sum.
# In a real production setup you'd commit go.sum to the repo so builds are deterministic;
# for this demo we generate it at build time for simplicity.
RUN go mod tidy

# CGO_ENABLED=0 produces a fully static binary that runs in a minimal image.
RUN CGO_ENABLED=0 GOOS=linux go build -o payments-service .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
WORKDIR /app
COPY --from=builder /build/payments-service ./
EXPOSE 8080
CMD ["./payments-service"]
