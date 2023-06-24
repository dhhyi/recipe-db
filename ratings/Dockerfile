FROM debian:12 as builder

RUN apt-get update && apt-get install -y \
    build-essential git libpcre3-dev libevent-dev cmake sudo

RUN useradd -ms /bin/bash io && usermod -aG sudo io && echo "io ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
USER io
ENV HOME=/home/io

ARG IO_VERSION=master

RUN git clone -b ${IO_VERSION} --single-branch --depth 1 --recursive https://github.com/IoLanguage/io.git /tmp/io
RUN cd /tmp/io && mkdir build && cd build && cmake -DCMAKE_BUILD_TYPE=release -DCMAKE_INSTALL_PREFIX=${HOME}/.local .. && make && make install

ENV PATH=${PATH}:${HOME}/.local/bin LD_LIBRARY_PATH=${HOME}/.local/lib
ENV EERIEDIR=${HOME}/.eerie PATH=${PATH}:${HOME}/.eerie/base/bin:${HOME}/.eerie/activeEnv/bin
RUN cd /tmp/io/build && io setup.io
WORKDIR ${HOME}

RUN eerie install https://github.com/IoLanguage/Regex.git
RUN eerie install https://github.com/IoLanguage/Random.git
RUN eerie install https://github.com/IoLanguage/CGI.git
RUN eerie install https://github.com/IoLanguage/Socket.git
RUN sudo apt-get install -y libsqlite3-dev
RUN eerie install https://github.com/IoLanguage/SQLite3.git

RUN find ${HOME}/.eerie -type d -name .git -print -exec rm -rf {} +
RUN rm -rf ${HOME}/.eerie/env/_base

FROM debian:12-slim
RUN apt-get update && apt-get install -y \
    libpcre3 libevent-2.1-7 libsqlite3-0 && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    useradd -Ms /bin/false io
USER io
ENV HOME=/home/io

ENV PATH=${PATH}:${HOME}/.local/bin LD_LIBRARY_PATH=${HOME}/.local/lib

COPY --from=builder ${HOME} ${HOME}

# RUN io -e '"12345" println' | grep 12345 && \
#     io -e 'Random clone ; "12345" println' | grep 12345 && \
#     io -e 'SQLite3 clone ; "12345" println' | grep 12345

WORKDIR /app
ENTRYPOINT [ "io" ]

EXPOSE 8456
COPY *.io .
COPY lib ./lib
