FROM debian:12 as builder

RUN apt-get update && apt-get install -y build-essential git cmake

ARG IO_VERSION=master
ENV HOME=/home/io

RUN git clone -b ${IO_VERSION} --single-branch --depth 1 --recursive https://github.com/IoLanguage/io.git /tmp/io
RUN cd /tmp/io && mkdir build && cd build && cmake -DCMAKE_BUILD_TYPE=release -DCMAKE_INSTALL_PREFIX=${HOME}/.local .. && make && make install

ENV PATH=${PATH}:${HOME}/.local/bin:${HOME}/.eerie/base/bin
ENV LD_LIBRARY_PATH=${HOME}/.local/lib
ENV EERIEDIR=${HOME}/.eerie

RUN cd /tmp/io/build && io setup.io
WORKDIR ${HOME}

# RUN eerie install https://github.com/IoLanguage/Random.git
# RUN apt-get install -y libpcre3-dev && eerie install https://github.com/IoLanguage/Regex.git
RUN eerie install https://github.com/IoLanguage/CGI.git
RUN apt-get install -y libevent-dev && eerie install https://github.com/IoLanguage/Socket.git
RUN apt-get install -y libsqlite3-dev && eerie install https://github.com/IoLanguage/SQLite3.git
RUN eerie pkg:list > /installed_packages

RUN find ${HOME}/.eerie -type d -name .git -print -exec rm -rf {} +
RUN rm -rf ${HOME}/.eerie/env/_base

FROM scratch as minimal
COPY --from=builder /home/io/.local/bin /usr/bin
COPY --from=builder /home/io/.local/lib /usr/lib
COPY --from=builder /home/io/.eerie /home/io/.eerie
COPY --from=builder /installed_packages /installed_packages

FROM debian:12-slim
RUN apt-get update && apt-get install -y \
# libpcre3 \
libevent-2.1-7 \
libsqlite3-0 \
&& apt-get clean && rm -rf /var/lib/apt/lists/* && \
useradd -Ms /bin/false io

USER io

COPY --from=minimal / /

WORKDIR /app
ENTRYPOINT [ "io" ]

EXPOSE 8456
COPY *.io .
COPY lib ./lib
