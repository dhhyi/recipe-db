FROM node:lts-alpine

RUN npm install -g json-server

WORKDIR /app
COPY db.json .

EXPOSE 3000

ENTRYPOINT ["json-server", "--watch", "db.json", "--host", "0.0.0.0"]
