FROM node:26-bookworm@sha256:a856ae5e25d498bbe5ec85fde88f00f5ed99908fda803ba39d7735ab8574f58c

ARG CHROME_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends chromium fonts-noto-color-emoji unzip \
  && rm -rf /var/lib/apt/lists/*
RUN sh -c 'if [ "$(dpkg --print-architecture)" = amd64 ]; then curl -fsSL "https://storage.googleapis.com/chrome-for-testing-public/${CHROME_VERSION}/linux64/chrome-linux64.zip" -o /tmp/chrome.zip && unzip -q /tmp/chrome.zip -d /opt/google && mv /opt/google/chrome-linux64 /opt/google/chrome && rm /tmp/chrome.zip; fi'
RUN npm install -g pnpm@12.6.0
WORKDIR /app
COPY browse-test/package.json browse-test/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile && chmod -R a+rX /app
COPY browse-test/playwright.config.js ./
COPY browse-test/tests ./tests
COPY demo-data/recipe1.json demo-data/recipe1.method.md demo-data/recipe1.jpg /demo-data/
CMD ["pnpm", "test"]
