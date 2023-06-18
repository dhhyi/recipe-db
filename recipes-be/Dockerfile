FROM node:lts-alpine

RUN npm install -g json-server

WORKDIR /app

EXPOSE 3000

ENTRYPOINT ["json-server", "--watch", "db.json", "--host", "0.0.0.0"]
