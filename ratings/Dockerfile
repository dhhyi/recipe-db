FROM debian:bookworm as builder

RUN apt-get update \
  && apt-get install -y build-essential git cmake

ARG IO_VERSION=master
ENV HOME=/root

RUN git clone -b ${IO_VERSION} --single-branch --depth 1 --recursive https://github.com/IoLanguage/io.git /tmp/io
RUN cd /tmp/io && mkdir build && cd build \
  && cmake -DCMAKE_BUILD_TYPE=release -DCMAKE_INSTALL_PREFIX=${HOME}/.local .. \
  && make && make install

ENV PATH=${PATH}:${HOME}/.local/bin:${HOME}/.eerie/base/bin
ENV LD_LIBRARY_PATH=${HOME}/.local/lib
ENV EERIEDIR=${HOME}/.eerie

RUN cd /tmp/io/build && io setup.io
WORKDIR ${HOME}

RUN apt-get install -y libpcre3-dev && eerie install https://github.com/IoLanguage/Regex.git
RUN eerie install https://github.com/IoLanguage/CGI.git
RUN apt-get install -y libevent-dev && eerie install https://github.com/IoLanguage/Socket.git
RUN apt-get install -y libsqlite3-dev && eerie install https://github.com/IoLanguage/SQLite3.git
RUN eerie pkg:list > /installed_packages

RUN find ${HOME}/.eerie -type d -name .git -print -exec rm -rf {} +
RUN rm -rf ${HOME}/.eerie/env/_base

FROM scratch as minimal
COPY --from=builder /root/.local/bin /usr/bin
COPY --from=builder /root/.local/lib /usr/lib
COPY --from=builder /root/.eerie /root/.eerie
COPY --from=builder /installed_packages /installed_packages
COPY *.io /app/
COPY lib /app/lib

FROM debian:bookworm-slim
RUN apt-get update \
  && apt-get install -y libpcre3 \
  && apt-get install -y libevent-2.1-7 \
  && apt-get install -y libsqlite3-0 \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=minimal / /

WORKDIR /app

ENTRYPOINT [ "io" ]

EXPOSE 8456
