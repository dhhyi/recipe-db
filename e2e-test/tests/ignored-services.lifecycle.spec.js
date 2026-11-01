import { test, expect } from "@playwright/test";
import { access } from "node:fs/promises";
import {
  ignoredServicesLifecycle,
  stackLock,
  stackSafety,
} from "./ignored-services.helpers.js";
import setup, { releaseStackLock } from "../stack-exclusivity.js";

test("configuration overrides cannot parallelize instance-wide mutations", async () => {
  for (const config of [
    { workers: 2, fullyParallel: false, projects: [] },
    { workers: 1, fullyParallel: true, projects: [] },
    {
      workers: 1,
      fullyParallel: false,
      projects: [{ fullyParallel: true }],
    },
  ]) {
    await expect(setup(config)).rejects.toThrow(
      "workers must be 1 and fullyParallel must be false",
    );
  }
});

test("another invocation cannot acquire the active stack lock", async () => {
  await expect(
    setup({ workers: 1, fullyParallel: false, projects: [] }),
  ).rejects.toThrow("The E2E stack is already locked");
});

test("an interrupted enable leaves a marker that prevents global lock release", async () => {
  let abort;
  let started;
  const enabling = new Promise((resolve) => {
    started = resolve;
  });
  const lifecycle = ignoredServicesLifecycle(async (names) => {
    if (!names.length) return [];
    return new Promise((resolve, reject) => {
      abort = reject;
      started();
    });
  });
  // A suspended enable models an exited worker that never reaches finally.
  const attempt = lifecycle.ignoreAndUse(["search"], async () => {});
  await enabling;
  try {
    await expect(releaseStackLock()).rejects.toThrow(
      "Ignored-service cleanup is unconfirmed",
    );
    await expect(access(stackLock)).resolves.toBeUndefined();
    await expect(
      setup({ workers: 1, fullyParallel: false, projects: [] }),
    ).rejects.toThrow("The E2E stack is already locked");
  } finally {
    abort(new Error("interrupted enable"));
    await expect(attempt).rejects.toThrow("interrupted enable");
  }
  await expect(access(`${stackLock}/active`)).rejects.toMatchObject({
    code: "ENOENT",
  });
});

function harness({
  failIgnore = false,
  failClear = false,
  clearResult = [],
} = {}) {
  const calls = [];
  let poisoned = false;
  let active = false;
  const lifecycle = ignoredServicesLifecycle(
    async (names) => {
      if (names.length) expect(active).toBe(true);
      calls.push([...names]);
      if (names.length && failIgnore) throw new Error("ignore failed");
      if (!names.length && failClear) throw new Error("cleanup failed");
      return names.length ? [...new Set(names)] : clearResult;
    },
    {
      async assertSafe() {
        if (poisoned || active) throw new Error("no later reset allowed");
      },
      async markActive() {
        active = true;
      },
      async confirmClear() {
        active = false;
      },
      async poison() {
        poisoned = true;
      },
    },
  );
  return { lifecycle, calls };
}

test("failed test attempt restores services before a retry resets data", async () => {
  const { lifecycle, calls } = harness();
  const attempt = () =>
    lifecycle.resetAndUse(
      async () => calls.push("reset"),
      () =>
        lifecycle.ignoreAndUse(["search", "search", "tags"], async () => {
          throw new Error("test failed");
        }),
    );
  await expect(attempt()).rejects.toThrow("test failed");
  await lifecycle.resetAndUse(
    async () => calls.push("retry reset"),
    async () => calls.push("retry"),
  );
  expect(calls).toEqual([
    [],
    "reset",
    ["search", "search", "tags"],
    [],
    [],
    [],
    "retry reset",
    "retry",
    [],
  ]);
});

test("an ignore setup failure still restores services", async () => {
  const { lifecycle, calls } = harness({ failIgnore: true });
  await expect(
    lifecycle.ignoreAndUse(["search"], async () => calls.push("test")),
  ).rejects.toThrow("ignore failed");
  expect(calls).toEqual([["search"], []]);
});

test("a reset or seed setup failure still restores services", async () => {
  for (const phase of ["reset", "seed"]) {
    const { lifecycle, calls } = harness();
    await expect(
      lifecycle.resetAndUse(
        async () => {
          calls.push("reset");
          if (phase === "reset") throw new Error("reset failed");
        },
        async () => {
          throw new Error("seed failed");
        },
      ),
    ).rejects.toThrow(`${phase} failed`);
    expect(calls).toEqual([[], "reset", []]);
  }
});

test("explicit cleanup failure poisons the stack and forbids later resets", async () => {
  const { lifecycle, calls } = harness({ failClear: true });
  await expect(
    lifecycle.ignoreAndUse(["search"], async () => calls.push("test")),
  ).rejects.toThrow("Failed to restore ignored services");
  await expect(
    lifecycle.resetAndUse(
      async () => calls.push("forbidden reset"),
      async () => calls.push("forbidden test"),
    ),
  ).rejects.toThrow("no later reset allowed");
  expect(calls).toEqual([["search"], "test", []]);
});

test("failed initial clearing never performs a data reset", async () => {
  const { lifecycle, calls } = harness({ failClear: true });
  await expect(
    lifecycle.resetAndUse(
      async () => calls.push("forbidden reset"),
      async () => calls.push("forbidden test"),
    ),
  ).rejects.toThrow("Failed to restore ignored services");
  await expect(
    lifecycle.resetAndUse(async () => calls.push("later reset"), async () => {}),
  ).rejects.toThrow("no later reset allowed");
  expect(calls).toEqual([[], []]);
});

test("a nonempty cleanup response is a failure, not a healthy stack", async () => {
  const { lifecycle, calls } = harness({ clearResult: ["search"] });
  await expect(
    lifecycle.ignoreAndUse(["search"], async () => {}),
  ).rejects.toThrow("Failed to restore ignored services");
  await expect(
    lifecycle.resetAndUse(
      async () => calls.push("forbidden reset"),
      async () => {},
    ),
  ).rejects.toThrow("no later reset allowed");
  expect(calls).toEqual([["search"], []]);
});

test("an outer successful cleanup does not permit resets after an inner failure", async () => {
  let poisoned = false;
  let clears = 0;
  const calls = [];
  const lifecycle = ignoredServicesLifecycle(
    async (names) => {
      calls.push(names);
      if (!names.length && ++clears === 2) {
        throw new Error("inner cleanup failed");
      }
      return names;
    },
    {
      async assertSafe() {
        if (poisoned) throw new Error("no later reset allowed");
      },
      async markActive() {},
      async confirmClear() {},
      async poison() {
        poisoned = true;
      },
    },
  );
  await expect(
    lifecycle.resetAndUse(
      async () => calls.push("reset"),
      () => lifecycle.ignoreAndUse(["search"], async () => {}),
    ),
  ).rejects.toThrow("Failed to restore ignored services");
  await expect(
    lifecycle.resetAndUse(
      async () => calls.push("forbidden reset"),
      async () => {},
    ),
  ).rejects.toThrow("no later reset allowed");
  expect(calls).toEqual([[], "reset", ["search"], [], []]);
});
