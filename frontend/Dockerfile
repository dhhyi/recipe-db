FROM golang:bookworm AS builder

WORKDIR /ws

COPY go.mod go.sum /ws/
RUN go mod download
RUN go install github.com/a-h/templ/cmd/templ@latest

COPY *.go *.templ genqlient.yaml recipe-db.graphqls operations.graphql /ws/
COPY src /ws/src
RUN go run github.com/Khan/genqlient@main
RUN templ generate
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o main .

FROM scratch

WORKDIR /app
COPY --from=builder /ws/main /app/

EXPOSE 3000

CMD ["/app/main"]
