FROM python:3-slim-bookworm as base

RUN apt-get update && apt-get install -y cron tini && apt-get clean
RUN pip install ariadne-codegen

WORKDIR /app
COPY *.graphql *.py *.toml *.sh recipe* /app/
RUN chmod +x /app/start.sh

CMD [ "tini", "--", "/bin/sh", "/app/start.sh" ]

FROM base as production

FROM base
ENV RESET_CRONTAB="@reboot"
