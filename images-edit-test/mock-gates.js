export function createMockGates() {
  const gates = new Map();

  function hold(name) {
    if (typeof name !== "string" || name.trim() === "") {
      throw new Error("GraphQL gate name is required");
    }
    if (gates.has(name)) {
      throw new Error(`GraphQL gate already held: ${name}`);
    }

    let start;
    let release;
    const started = new Promise((resolve) => {
      start = resolve;
    });
    const released = new Promise((resolve) => {
      release = resolve;
    });
    const gate = { started, start, released, release, pending: new Set() };
    gates.set(name, gate);
    return { started, release };
  }

  async function run(name, respond) {
    const gate = gates.get(name);
    if (!gate) return respond();

    gate.start();
    const pending = (async () => {
      await gate.released;
      await respond();
    })();
    gate.pending.add(pending);
    try {
      await pending;
    } finally {
      gate.pending.delete(pending);
    }
  }

  async function releaseAll() {
    for (const gate of gates.values()) gate.release();
    await Promise.all([...gates.values()].flatMap((gate) => [...gate.pending]));
  }

  return { hold, run, releaseAll };
}
