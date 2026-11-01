import { access, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

export const ignoredAuxiliaryServices = [
  "search",
  "ratings",
  "inspirations",
  "images",
  "tags",
  "image-inline",
  "link-extract",
];

export const stackLock = fileURLToPath(
  new URL("../target/outage-stack.lock", import.meta.url),
);

export const stackSafety = {
  async assertSafe() {
    try {
      await access(`${stackLock}/cleanup-failed`);
    } catch (error) {
      if (error.code === "ENOENT") return;
      throw error;
    }
    throw new Error(
      "Ignored-service cleanup failed; no later data reset is allowed. Restore setIgnoredServices(names: []) and remove target/outage-stack.lock before retrying.",
    );
  },
  async poison() {
    await writeFile(`${stackLock}/cleanup-failed`, "cleanup failed\n");
  },
};

export function ignoredServicesLifecycle(mutate, safety = stackSafety) {
  async function clear() {
    try {
      const effective = await mutate([]);
      if (!Array.isArray(effective) || effective.length !== 0) {
        throw new Error("Clearing ignored services did not return an empty list");
      }
    } catch (error) {
      await safety.poison();
      throw new Error("Failed to restore ignored services", { cause: error });
    }
  }

  return {
    async resetAndUse(reset, use) {
      await safety.assertSafe();
      try {
        await clear();
        await reset();
        await use();
      } finally {
        await clear();
      }
    },
    async ignoreAndUse(names, use) {
      await safety.assertSafe();
      try {
        const effective = await mutate(names);
        const expected = [...new Set(names)];
        if (
          !Array.isArray(effective) ||
          JSON.stringify(effective) !== JSON.stringify(expected)
        ) {
          throw new Error("Ignored services did not match the requested list");
        }
        await use();
      } finally {
        await clear();
      }
    },
  };
}
