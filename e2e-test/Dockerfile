FROM node:26-trixie@sha256:6d2c7d5d074bf72f81ddc252b4fbb5d625bc028eeda49cb4b8c2ff8eda1ee617

ARG PLAYWRIGHT_VERSION
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npm install -g pnpm@12.6.0 playwright@${PLAYWRIGHT_VERSION}
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile && pnpm exec playwright install --with-deps chromium && chmod -R a+rX /app /ms-playwright
COPY playwright.config.js ./
COPY tests ./tests
CMD ["pnpm", "test"]
