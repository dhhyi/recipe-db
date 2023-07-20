FROM debian
RUN apt-get update && apt-get install -y \
  perl \
  libdancer2-perl \
  libswitch-perl \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY server.pl .
EXPOSE 3000
CMD ["perl", "server.pl"]
