# syntax=docker/dockerfile:1
FROM golang:1.26-alpine3.23 AS builder
WORKDIR /src
RUN apk update && apk update && apk add --no-cache ca-certificates
COPY go.mod ./
RUN go mod download
COPY src/ ./src/
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o /out/api ./src

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app
COPY --from=builder --chown=nonroot:nonroot /out/api /app/api
ENV LISTEN_ADDR=:8080
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/app/api"]
