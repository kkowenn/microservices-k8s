FROM golang:1.22-alpine AS build
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY main.go .
RUN go build -o api .

FROM alpine:3.20
WORKDIR /app
COPY --from=build /app/api .
EXPOSE 8000
CMD ["./api"]
