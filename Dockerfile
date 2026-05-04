FROM golang:1.25-alpine AS builder

WORKDIR /app

COPY go.mod ./
# No go.sum yet since there are no external dependencies
# COPY go.sum ./
# RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o ping-pong .

FROM scratch

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /app/ping-pong /ping-pong

USER 65534:65534

ENTRYPOINT ["/ping-pong"]
