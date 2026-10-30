# check=skip=InvalidDefaultArgInFrom

# Versions are supplied by the generated Compose build arguments.
ARG PYTHON_VERSION
FROM python:${PYTHON_VERSION}-slim-trixie@sha256:94d3426f1def7db4a106a232ac121bfd975393e5dfd40a619b955fae45fe7913

RUN pip install ariadne-codegen

WORKDIR /app
COPY *.graphql *.py *.toml *.sh recipe* tags.json /app/
RUN chmod +x /app/generate.sh

CMD [ "/app/generate.sh" ]
