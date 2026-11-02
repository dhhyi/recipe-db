import { test, expect } from "@playwright/test";
import { withIgnoredServices } from "./fixtures.js";

function requestStub(update) {
  return {
    async post(_path, { data: { variables } }) {
      const names = await update(variables.names);
      return {
        ok: () => true,
        status: () => 200,
        text: async () =>
          JSON.stringify({ data: { setIgnoredServices: names } }),
      };
    },
  };
}

for (const failure of ["setup", "test", "cleanup", null]) {
  test(`ignored services cleanup after ${failure ?? "a successful attempt"}`, async () => {
    const calls = [];
    const request = requestStub(async (names) => {
      calls.push(names);
      if (failure === "setup" && names.length) throw new Error("setup failed");
      if (failure === "cleanup" && !names.length)
        throw new Error("cleanup failed");
      return names;
    });
    const attempt = withIgnoredServices(request, ["search"], async () => {
      calls.push("test");
      if (failure === "test") throw new Error("test failed");
    });
    if (failure) {
      await expect(attempt).rejects.toThrow(`${failure} failed`);
    } else {
      await attempt;
    }
    expect(calls).toEqual(
      failure === "setup" ? [["search"], []] : [["search"], "test", []],
    );
  });
}

test("clearing precedes data reset and cleanup rejects a nonempty result", async () => {
  const calls = [];
  const request = requestStub(async (names) => {
    calls.push(names);
    return calls.length === 1 ? [] : ["search"];
  });
  await expect(
    withIgnoredServices(request, [], async () => calls.push("reset")),
  ).rejects.toThrow();
  expect(calls).toEqual([[], "reset", []]);
});
