FROM python:slim

RUN pip install ariadne-codegen

WORKDIR /app
COPY *.graphql *.py *.toml *.sh recipe* /app/

ENTRYPOINT [ "/bin/sh", "-Ec", "cd /app && sh -Ee generate.sh" ]
