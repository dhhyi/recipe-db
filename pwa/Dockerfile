FROM nginx:stable-alpine@sha256:0e52bd054126cdc040b1276c0af347aeb02a41b9cfe305d6094767ac30e97949
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY manifest.webmanifest /usr/share/nginx/html/pwa/manifest.webmanifest
COPY icons/ /usr/share/nginx/html/pwa/icons/
