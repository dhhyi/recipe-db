import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  timeout: 60_000,
  expect: { timeout: 15_000 },
  outputDir: "target/test-results",
  reporter: [
    ["list"],
    ["html", { outputFolder: "target/playwright-report", open: "never" }],
    ["junit", { outputFile: "target/junit.xml" }],
  ],
  use: {
    baseURL: process.env.BASE_URL || "http://traefik",
    locale: "de-DE",
    timezoneId: "Europe/Berlin",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [
    {
      // Google Chrome is not available for Linux ARM64.
      name: process.arch === "arm64" ? "chromium-arm64" : "chrome",
      use: {
        ...devices["Desktop Chrome"],
        channel: process.arch === "arm64" ? undefined : "chrome",
        launchOptions:
          process.arch === "arm64"
            ? { executablePath: "/usr/bin/chromium" }
            : {},
      },
    },
  ],
});
