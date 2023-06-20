FROM ghcr.io/dhhyi/dcc-devcontainer-io

USER vscode

RUN eerie install https://github.com/IoLanguage/Socket.git
RUN eerie install https://github.com/IoLanguage/CGI.git

EXPOSE 8456

WORKDIR /app

COPY *.io .

ENTRYPOINT [ "io" ]