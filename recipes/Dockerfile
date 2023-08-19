FROM golang:bookworm as builder

WORKDIR /ws

COPY go.mod go.sum /ws/
RUN go mod download

COPY recipes.go /ws/
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o main .

FROM scratch

WORKDIR /app
COPY --from=builder /ws/main /app/

ENV GIN_MODE=release

EXPOSE 5000

CMD ["/app/main"]
