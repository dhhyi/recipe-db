import { access, rm, writeFile } from "node:fs/promises";
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
    for (const marker of ["cleanup-failed", "active"]) {
      try {
        await access(`${stackLock}/${marker}`);
      } catch (error) {
        if (error.code === "ENOENT") continue;
        throw error;
      }
      throw new Error(
        "Ignored-service cleanup is unconfirmed; no later data reset is allowed. Restore setIgnoredServices(names: []) and remove target/outage-stack.lock before retrying.",
      );
    }
  },
  async markActive() {
    await writeFile(`${stackLock}/active`, "cleanup unconfirmed\n");
  },
  async confirmClear() {
    await rm(`${stackLock}/active`, { force: true });
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
      await safety.confirmClear();
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
        if (names.length) await safety.markActive();
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
