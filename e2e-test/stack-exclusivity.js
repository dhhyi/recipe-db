import { mkdir, rm } from "node:fs/promises";
import { stackLock, stackSafety } from "./tests/ignored-services.helpers.js";

export default async function setup(config) {
  if (
    config.workers !== 1 ||
    config.projects.some((project) => project.fullyParallel)
  ) {
    throw new Error(
      "E2E tests mutate instance-wide state: workers must be 1 and fullyParallel must be false.",
    );
  }
  await mkdir(new URL("./target/", import.meta.url), { recursive: true });
  try {
    await mkdir(stackLock);
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
    throw new Error(
      "The E2E stack is already locked. Do not run concurrent tests against this stack. If cleanup failed, restore setIgnoredServices(names: []) before removing target/outage-stack.lock.",
    );
  }
  return async () => {
    await stackSafety.assertSafe();
    await rm(stackLock, { recursive: true });
  };
}
