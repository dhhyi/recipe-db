FROM node:lts-bookworm as builder
RUN npm i -g elm @dillonkearns/elm-graphql
WORKDIR /app
COPY . .
RUN npm run codegen -- --skip-elm-format
RUN elm make src/Main.elm --optimize --output=elm.js

FROM nginx:stable-alpine
# COPY nginx.conf /etc/nginx/templates/default.conf.template
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html
COPY --from=builder /app/elm.js /usr/share/nginx/html
