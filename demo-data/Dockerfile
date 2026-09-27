FROM python:3-slim-bookworm@sha256:82bc3c539b8813ada9d68c63b40158fa002f7f33de9bf3312a3dfdc0620dff56

RUN pip install ariadne-codegen

WORKDIR /app
COPY *.graphql *.py *.toml *.sh recipe* /app/
RUN chmod +x /app/generate.sh

CMD [ "/app/generate.sh" ]
