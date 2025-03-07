# Start with a minimal base image
FROM golang:1.24 AS builder

WORKDIR /app

COPY main.go main.go
COPY go.sum go.sum
COPY go.mod go.mod

# Build the application as a static binary
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o app main.go

# Use a minimal runtime image
FROM alpine:latest
WORKDIR /root/

# Copy the built binary
COPY --from=builder /app/app .

# Run the application
CMD ["./app"]

