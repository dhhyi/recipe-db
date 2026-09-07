FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
  tini \
  perl \
  libdancer2-perl \
  libswitch-perl \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY server.pl .
EXPOSE 3000
ENTRYPOINT [ "tini", "--" ]
CMD [ "perl", "server.pl" ]
