FROM python:slim

RUN pip install ariadne-codegen

WORKDIR /app
COPY *.graphql *.py *.toml *.sh recipe* /app/
