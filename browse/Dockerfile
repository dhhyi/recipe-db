FROM golang:trixie@sha256:c65ecfe613b539ac74c62a4c3b2c27e8f8a6076384c8f27e8a3c0f3be17cc385 AS builder

WORKDIR /ws

COPY go.mod go.sum /ws/
RUN go mod download
RUN go install github.com/a-h/templ/cmd/templ@v0.3.1020

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
