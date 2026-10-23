FROM node:26-trixie@sha256:a98e6fda54fdbb22d4238054cca9a2a113bcd1191c09193a535aae22f400aa8e

ARG PLAYWRIGHT_VERSION
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npm install -g pnpm@12.6.0 playwright@${PLAYWRIGHT_VERSION}
WORKDIR /app
COPY e2e-test/package.json e2e-test/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile && pnpm exec playwright install --with-deps chromium && chmod -R a+rX /app /ms-playwright
COPY e2e-test/playwright.config.js ./
COPY e2e-test/tests ./tests
COPY demo-data/recipe1.json demo-data/recipe1.method.md demo-data/recipe1.jpg demo-data/recipe2.jpg /demo-data/
CMD ["pnpm", "test"]
