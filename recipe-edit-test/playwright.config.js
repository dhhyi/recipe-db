import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  timeout: 45_000,
  expect: { timeout: 15_000 },
  outputDir: "target/test-results",
  reporter: [
    ["list"],
    ["html", { outputFolder: "target/playwright-report", open: "never" }],
    ["junit", { outputFile: "target/junit.xml" }],
  ],
  snapshotPathTemplate:
    "{testDir}/__screenshots__/{projectName}/{testFilePath}/{arg}{ext}",
  use: {
    baseURL: process.env.BASE_URL || "http://traefik",
    locale: "de-DE",
    timezoneId: "Europe/Berlin",
    colorScheme: "light",
    reducedMotion: "reduce",
    serviceWorkers: "block",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [
    {
      name: "mobile",
      use: {
        ...devices["Pixel 7"],
        viewport: { width: 390, height: 844 },
      },
    },
    {
      name: "mobile-landscape",
      testMatch: "**/*.visual.spec.js",
      use: {
        ...devices["Pixel 7 landscape"],
        viewport: { width: 844, height: 390 },
      },
    },
    {
      name: "tablet",
      testMatch: "**/*.visual.spec.js",
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 768, height: 1024 },
        hasTouch: true,
        colorScheme: "dark",
      },
    },
    {
      name: "desktop",
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 1280, height: 900 },
      },
    },
  ],
});
