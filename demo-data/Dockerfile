FROM python:3-slim-bookworm

RUN pip install ariadne-codegen

WORKDIR /app
COPY *.graphql *.py *.toml *.sh recipe* /app/
RUN chmod +x /app/generate.sh

CMD [ "/app/generate.sh" ]
