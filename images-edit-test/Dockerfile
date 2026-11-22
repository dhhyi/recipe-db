FROM node:26-trixie@sha256:6d2c7d5d074bf72f81ddc252b4fbb5d625bc028eeda49cb4b8c2ff8eda1ee617

ARG PLAYWRIGHT_VERSION
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npm install -g pnpm@12.6.0 playwright@${PLAYWRIGHT_VERSION}
WORKDIR /app
RUN playwright install --with-deps chromium
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile && local_version="$(pnpm exec playwright --version)" && global_version="$(playwright --version)" && printf 'Playwright versions must match: project=%s, global=%s\n' "$local_version" "$global_version" && test "$local_version" = "$global_version" && chmod -R a+rX /app /ms-playwright
COPY playwright.config.js fixtures.js mock-validation.js recipe-db.graphqls screenshot.css ./
COPY tests ./tests
CMD ["pnpm", "integration"]
