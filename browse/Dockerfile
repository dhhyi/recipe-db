FROM golang:bookworm@sha256:69a7b9788769bec032d238959b61854e9ae87f57be9029ec04e9885fabf99195 AS builder

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
