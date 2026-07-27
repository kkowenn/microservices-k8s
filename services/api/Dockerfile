FROM golang:1.22-alpine AS build
WORKDIR /app
COPY go.mod .
COPY main.go .
RUN go build -o api .

FROM alpine:3.20
WORKDIR /app
COPY --from=build /app/api .
EXPOSE 3000
CMD ["./api"]
