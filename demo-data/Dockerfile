# check=skip=InvalidDefaultArgInFrom

# Versions are supplied by the generated Compose build arguments.
ARG PYTHON_VERSION
FROM python:${PYTHON_VERSION}-slim-bookworm@sha256:4e03260adeeebafccd084f3584e6b84823aba5651cfb53ef8a078ed441ddf9cd

RUN pip install ariadne-codegen

WORKDIR /app
COPY *.graphql *.py *.toml *.sh recipe* /app/
RUN chmod +x /app/generate.sh

CMD [ "/app/generate.sh" ]
