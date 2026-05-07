# Multi-stage build: compile in golang image, copy binary into tiny runtime image.
# Final image is ~15MB instead of ~800MB. This matters for ECR storage costs and pull times in ECS.
FROM golang:1.22-alpine AS builder
WORKDIR /build
COPY go.mod ./
COPY main.go ./
# CGO_ENABLED=0 produces a fully static binary that runs in scratch/distroless images.
RUN CGO_ENABLED=0 GOOS=linux go build -o payments-service main.go

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
WORKDIR /app
COPY --from=builder /build/payments-service ./
EXPOSE 8080
CMD ["./payments-service"]
