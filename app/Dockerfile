# Build stage
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /trdl .

# Runtime stage
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /trdl /trdl
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/trdl"]
