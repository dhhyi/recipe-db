FROM debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251 AS builder

RUN apt-get update \
  && apt-get install -y build-essential git cmake

ARG IO_VERSION
ENV HOME=/root

RUN test -n "$IO_VERSION" && git clone --branch native --recursive https://github.com/IoLanguage/io.git /tmp/io
RUN cd /tmp/io && git checkout $IO_VERSION
# Use glibc's ucontext on Linux ARM64; Io's custom ARM64 assembly is macOS-only.
RUN sed -i 's/^#if !defined(__arm64__) \&\& !defined(__aarch64__)$/#if defined(__linux__) || (!defined(__arm64__) \&\& !defined(__aarch64__))/' /tmp/io/libs/coroutine/source/Coro.c \
  && sed -i 's/^#if defined(__arm64__) || defined(__aarch64__)$/#if !defined(__linux__) \&\& (defined(__arm64__) || defined(__aarch64__))/' /tmp/io/libs/coroutine/source/Coro_arm64.c
RUN cd /tmp/io && mkdir build && cd build \
  && cmake -DCMAKE_BUILD_TYPE=release -DCMAKE_INSTALL_PREFIX=${HOME}/.local .. \
  && make && make install

ENV PATH=${PATH}:${HOME}/.local/bin:${HOME}/.eerie/base/bin
ENV LD_LIBRARY_PATH=${HOME}/.local/lib
ENV EERIEDIR=${HOME}/.eerie

COPY tests/coroutines.io /tmp/coroutines.io
RUN timeout 10 io /tmp/coroutines.io

RUN cd /tmp/io/build && io setup.io
WORKDIR ${HOME}

RUN apt-get install -y libpcre3-dev && eerie install https://github.com/IoLanguage/Regex.git
RUN eerie install https://github.com/IoLanguage/CGI.git
RUN apt-get install -y libevent-dev && eerie install https://github.com/IoLanguage/Socket.git
RUN apt-get install -y libsqlite3-dev && eerie install https://github.com/IoLanguage/SQLite3.git
RUN eerie pkg:list > /installed_packages

RUN find ${HOME}/.eerie -type d -name .git -print -exec rm -rf {} +
RUN rm -rf ${HOME}/.eerie/env/_base

FROM scratch AS minimal
COPY --from=builder /root/.local/bin /usr/bin
COPY --from=builder /root/.local/lib /usr/lib
COPY --from=builder /root/.eerie /root/.eerie
COPY --from=builder /installed_packages /installed_packages
COPY *.io /app/
COPY lib /app/lib

FROM debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251
RUN apt-get update \
  && apt-get install -y libpcre3 \
  && apt-get install -y libevent-2.1-7 \
  && apt-get install -y libsqlite3-0 \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=minimal / /

WORKDIR /app

ENTRYPOINT [ "io" ]

EXPOSE 8456
