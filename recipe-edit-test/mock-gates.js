export function createMockGates() {
  const gates = new Map();

  function hold(operationName) {
    if (typeof operationName !== "string" || operationName.trim() === "") {
      throw new Error("GraphQL operation name is required");
    }
    if (gates.has(operationName)) {
      throw new Error(`GraphQL operation already held: ${operationName}`);
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
    gates.set(operationName, gate);
    return { started, release };
  }

  async function run(operationName, respond) {
    const gate = gates.get(operationName);
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
