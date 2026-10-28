FROM golang:bookworm@sha256:d9b6a1beb9474adc2a1ce842573639b44b2a0dd49b6669f51d3821baf9ec37c9 AS builder

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
