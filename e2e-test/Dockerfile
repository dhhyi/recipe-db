FROM node:26-trixie@sha256:97fa0f1b59035c6072721a88d55be1371c7cb1cc942b521e1cc5c72ec87655f4

ARG PLAYWRIGHT_VERSION
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npm install -g pnpm@12.6.0 playwright@${PLAYWRIGHT_VERSION}
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile && pnpm exec playwright install --with-deps chromium && chmod -R a+rX /app /ms-playwright
COPY playwright.config.js ./
COPY tests ./tests
CMD ["pnpm", "test"]
