FROM golang:trixie@sha256:c65ecfe613b539ac74c62a4c3b2c27e8f8a6076384c8f27e8a3c0f3be17cc385 AS builder

ARG TARGETARCH
WORKDIR /ws

COPY go.mod go.sum /ws/
RUN --mount=type=cache,id=browse-go-mod,target=/go/pkg/mod,sharing=locked \
  go mod download
ARG TEMPL_VERSION
RUN --mount=type=cache,id=browse-go-mod,target=/go/pkg/mod,sharing=locked \
  --mount=type=cache,id=browse-go-build-${TARGETARCH},target=/root/.cache/go-build,sharing=locked \
  << 'EOF'
set -eu
runtime_version="$(go list -m -f '{{.Version}}' github.com/a-h/templ)"
if [ "${TEMPL_VERSION}" != "${runtime_version}" ]; then
  echo "templ version mismatch: TEMPL_VERSION=${TEMPL_VERSION}, go.mod runtime=${runtime_version}" >&2
  exit 1
fi
go install "github.com/a-h/templ/cmd/templ@${TEMPL_VERSION}"
EOF

COPY *.go *.templ genqlient.yaml recipe-db.graphqls operations.graphql /ws/
COPY page_metadata /ws/page_metadata
COPY src /ws/src
RUN --mount=type=cache,id=browse-go-mod,target=/go/pkg/mod,sharing=locked \
  --mount=type=cache,id=browse-go-build-${TARGETARCH},target=/root/.cache/go-build,sharing=locked \
  go run github.com/Khan/genqlient@main
RUN templ generate
RUN --mount=type=cache,id=browse-go-mod,target=/go/pkg/mod,sharing=locked \
  --mount=type=cache,id=browse-go-build-${TARGETARCH},target=/root/.cache/go-build,sharing=locked \
  CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o main .

FROM scratch

WORKDIR /app
COPY --from=builder /ws/main /app/

EXPOSE 3000

CMD ["/app/main"]
