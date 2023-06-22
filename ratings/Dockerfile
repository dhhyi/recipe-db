FROM ghcr.io/dhhyi/dcc-devcontainer-io

USER root

RUN apt-get update && export DEBIAN_FRONTEND=noninteractive && apt-get -y install --no-install-recommends libsqlite3-dev && apt-get clean && rm -rf /var/lib/apt/lists/*

USER vscode

RUN eerie install https://github.com/IoLanguage/Socket.git
RUN eerie install https://github.com/IoLanguage/CGI.git
RUN eerie install https://github.com/IoLanguage/SQLite3.git

EXPOSE 8456

WORKDIR /app

COPY *.io .
COPY lib ./lib

ENTRYPOINT [ "io" ]
