FROM node:26-trixie@sha256:a98e6fda54fdbb22d4238054cca9a2a113bcd1191c09193a535aae22f400aa8e

ARG PLAYWRIGHT_VERSION
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npm install -g pnpm@12.6.0 playwright@${PLAYWRIGHT_VERSION}
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile && pnpm exec playwright install --with-deps chromium && chmod -R a+rX /app /ms-playwright
COPY playwright.config.js ./
COPY tests ./tests
CMD ["pnpm", "test"]
