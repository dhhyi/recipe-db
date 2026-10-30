FROM debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS builder

ARG PCRE_VERSION
RUN apt-get update \
  && apt-get install -y build-essential git cmake wget pkg-config libevent-dev libmarkdown2-dev libsqlite3-dev \
  && rm -rf /var/lib/apt/lists/*

ARG IO_VERSION
ENV HOME=/root

RUN test -n "$IO_VERSION" && git clone --branch native --recursive https://github.com/IoLanguage/io.git /tmp/io
RUN cd /tmp/io && git checkout $IO_VERSION
RUN git clone https://github.com/IoLanguage/Markdown.git /opt/Markdown-patched \
  && sed -i 's/mkd_flag_t \*flags/mkd_flag_t flags/' /opt/Markdown-patched/source/IoMarkdown.c \
  && git -C /opt/Markdown-patched -c user.email=devcontainer@example.com -c user.name=devcontainer commit -am "patch for discount 2.2 mkd_flag_t API" \
  && git config --system url."file:///opt/Markdown-patched".insteadOf "https://github.com/IoLanguage/Markdown.git"
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

RUN test -n "$PCRE_VERSION" \
  && wget -q "https://sourceforge.net/projects/pcre/files/pcre/${PCRE_VERSION}/pcre-${PCRE_VERSION}.tar.gz/download" -O /tmp/pcre.tar.gz \
  && tar -xzf /tmp/pcre.tar.gz -C /tmp \
  && cd "/tmp/pcre-${PCRE_VERSION}" \
  && ./configure --prefix=/usr/local \
  && make && make install
RUN eerie install https://github.com/IoLanguage/Regex.git
RUN eerie install https://github.com/IoLanguage/CGI.git
RUN eerie install https://github.com/IoLanguage/Socket.git
RUN eerie install https://github.com/IoLanguage/SQLite3.git
RUN eerie pkg:list > /installed_packages

RUN find ${HOME}/.eerie -type d -name .git -print -exec rm -rf {} +
RUN rm -rf ${HOME}/.eerie/env/_base
RUN apt-get clean && rm -rf /var/lib/apt/lists/*

FROM scratch AS minimal
COPY --from=builder /root/.local/bin /usr/bin
COPY --from=builder /root/.local/lib /usr/lib
COPY --from=builder /root/.eerie /root/.eerie
COPY --from=builder /installed_packages /installed_packages
COPY *.io /app/
COPY lib /app/lib

FROM debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4
RUN apt-get update \
  && apt-get install -y libevent-2.1-7t64 \
  && apt-get install -y libsqlite3-0 \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=minimal / /
COPY --from=builder /usr/local/lib/libpcre.so* /usr/lib/

WORKDIR /app

ENTRYPOINT [ "io" ]

EXPOSE 8456
