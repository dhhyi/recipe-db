#!/bin/sh

if [ -n "$RESET_CRONTAB" ]; then
  if [ "$RESET_CRONTAB" = "@reboot" ]; then
    sleep 15
  fi

  echo "$RESET_CRONTAB sh -c 'export SERVICES=$SERVICES ; sh /app/generate.sh' >/proc/1/fd/1 2>/proc/1/fd/2" | crontab -
fi

crontab -l

exec cron -f
