const assert = require("node:assert/strict");
const fs = require("node:fs");
const test = require("node:test");
const vm = require("node:vm");

const html = fs.readFileSync("index.html", "utf8");
const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)][0][1];

function jpeg(width, height, orientation = 1, little = true) {
  const bytes = Buffer.alloc(50);
  bytes.writeUInt16BE(0xffd8, 0);
  bytes.writeUInt16BE(0xffe1, 2);
  bytes.writeUInt16BE(34, 4);
  bytes.write("Exif\0\0", 6, "binary");
  bytes.writeUInt16BE(little ? 0x4949 : 0x4d4d, 12);
  const short = (n, at) =>
    little ? bytes.writeUInt16LE(n, at) : bytes.writeUInt16BE(n, at);
  const long = (n, at) =>
    little ? bytes.writeUInt32LE(n, at) : bytes.writeUInt32BE(n, at);
  short(42, 14);
  long(8, 16);
  short(1, 20);
  short(0x112, 22);
  short(3, 24);
  long(1, 26);
  short(orientation, 30);
  bytes.writeUInt16BE(0xffc0, 38);
  bytes.writeUInt16BE(8, 40);
  bytes[42] = 8;
  bytes.writeUInt16BE(height, 43);
  bytes.writeUInt16BE(width, 45);
  bytes[47] = 1;
  bytes.writeUInt16BE(0xffd9, 48);
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length);
}

function png(width, height, orientation = null) {
  const bytes = Buffer.alloc(orientation === null ? 45 : 83);
  Buffer.from("89504e470d0a1a0a", "hex").copy(bytes);
  bytes.writeUInt32BE(13, 8);
  bytes.write("IHDR", 12);
  bytes.writeUInt32BE(width, 16);
  bytes.writeUInt32BE(height, 20);
  bytes[24] = 8;
  bytes[25] = 6;
  let offset = 33;
  if (orientation !== null) {
    bytes.writeUInt32BE(26, offset);
    bytes.write("eXIf", offset + 4);
    Buffer.from(jpeg(width, height, orientation)).copy(
      bytes,
      offset + 8,
      12,
      38,
    );
    offset += 38;
  }
  bytes.write("IEND", offset + 4);
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length);
}

function harness(options = {}) {
  const events = [];
  const metadata = [];
  const revoked = [];
  const decoded = [];
  const header = { inert: false };
  const windowListeners = new Map();
  const documentListeners = new Map();
  const navigations = [];
  const input = { value: "selected", files: [] };
  let receive;
  const app = {
    ports: {
      editorCommand: { subscribe: (fn) => (receive = fn) },
      editorEvent: {
        send: (event) =>
          (event.kind === "metadata" ? metadata : events).push(event),
      },
    },
  };
  class Image {
    constructor() {
      decoded.push(this);
      this.naturalWidth = options.width ?? 1200;
      this.naturalHeight = options.height ?? 900;
    }
    decode() {
      return options.decode ? options.decode() : Promise.resolve();
    }
  }
  vm.runInNewContext(script, {
    Elm: { Main: { init: () => app } },
    document: {
      querySelector: (selector) =>
        selector === "header-component" ? header : {},
      getElementById: () => input,
      addEventListener: (name, listener) =>
        documentListeners.set(name, listener),
    },
    window: {
      location: {
        href: "http://recipe.test/images/123",
        assign: (url) => navigations.push(url),
      },
      confirm: () => options.confirm ?? true,
      addEventListener: (name, listener) => windowListeners.set(name, listener),
      removeEventListener: (name) => windowListeners.delete(name),
    },
    URL: class extends URL {
      static createObjectURL() {
        return "blob:original";
      }
      static revokeObjectURL(url) {
        revoked.push(url);
      }
    },
    Image,
    DataView,
    Uint8Array,
  });
  return {
    events,
    metadata,
    revoked,
    decoded,
    header,
    windowListeners,
    navigations,
    dispatch: (name, event) => documentListeners.get(name)?.(event),
    click(url, extra = {}) {
      let prevented = false;
      const anchor = {
        matches: (selector) => selector === "a[href]",
        href: url,
        target: "",
        hasAttribute: () => false,
      };
      documentListeners.get("click")({
        composedPath: () => [{}, anchor],
        button: 0,
        preventDefault: () => {
          prevented = true;
        },
        stopImmediatePropagation() {},
        ...extra,
      });
      return prevented;
    },
    receive: (message) => receive(message),
    async load(buffer, overrides = {}) {
      input.files = [
        {
          type: "image/jpeg",
          size: buffer.byteLength,
          arrayBuffer: () => Promise.resolve(buffer),
          ...overrides,
        },
      ];
      receive({ action: "inspect", token: 1 });
      await new Promise(setImmediate);
      if (metadata.length && options.authorize !== false) {
        receive({ action: "decode", token: 1 });
        await new Promise(setImmediate);
      }
    },
  };
}

test("saving locks shared header navigation and clean state removes unload listener", () => {
  const bridge = harness();
  bridge.receive({ action: "guard", dirty: true, saving: true });
  assert.equal(bridge.header.inert, true);
  let prevented = false;
  const event = {
    preventDefault: () => {
      prevented = true;
    },
  };
  bridge.windowListeners.get("beforeunload")(event);
  assert.equal(prevented, true);
  assert.equal(event.returnValue, "");
  bridge.receive({ action: "guard", dirty: false, saving: false });
  assert.equal(bridge.header.inert, false);
  assert.equal(bridge.windowListeners.has("beforeunload"), false);
});

test("saving capture guard blocks in-app anchors, including composed paths", () => {
  const bridge = harness();
  bridge.receive({ action: "guard", dirty: true, saving: true });
  assert.equal(bridge.click("http://recipe.test/"), true);
  assert.equal(bridge.click("https://external.test/"), false);
  assert.equal(bridge.windowListeners.has("beforeunload"), true);
});

test("dirty in-app anchor departure confirms, while external/new-tab links retain native behavior", () => {
  const bridge = harness({ confirm: false });
  bridge.receive({ action: "guard", dirty: true, saving: false });
  assert.equal(bridge.click("http://recipe.test/"), true);
  assert.equal(bridge.click("http://recipe.test/", { ctrlKey: true }), false);
  assert.equal(bridge.click("https://external.test/"), false);
  assert.equal(bridge.windowListeners.has("beforeunload"), true);
});

test("accepted in-app anchor departure removes duplicate unload confirmation", () => {
  const bridge = harness();
  bridge.receive({ action: "guard", dirty: true, saving: false });
  assert.equal(bridge.click("http://recipe.test/"), false);
  assert.equal(bridge.windowListeners.has("beforeunload"), false);
});

test("active pointer coordinates do not jump when status layout moves the stage", () => {
  const bridge = harness();
  let top = 10;
  const stage = {
    dataset: { editable: "true" },
    getBoundingClientRect: () => ({ left: 20, top, width: 600, height: 450 }),
    setPointerCapture() {},
    hasPointerCapture: () => true,
    releasePointerCapture() {},
  };
  const target = {
    dataset: { handle: "move" },
    closest: (selector) => (selector === "[data-handle]" ? target : stage),
  };
  const event = {
    target,
    isPrimary: true,
    button: 0,
    pointerId: 1,
    clientX: 120,
    clientY: 110,
    preventDefault() {},
  };
  bridge.dispatch("pointerdown", event);
  top = 45;
  bridge.dispatch("pointerup", event);
  assert.equal(bridge.events[0].event, "start");
  assert.equal(bridge.events[1].event, "move");
  assert.equal(bridge.events[0].x, bridge.events[1].x);
  assert.equal(bridge.events[0].y, bridge.events[1].y);
  assert.equal(bridge.events[1].displayHeight, 450);
  assert.equal(bridge.events[2].kind, "end");
});

for (const little of [true, false]) {
  for (let orientation = 1; orientation <= 8; orientation++) {
    test(`EXIF ${orientation}, ${little ? "little" : "big"} endian uses oriented source dimensions`, async () => {
      const size =
        orientation >= 5
          ? { width: 900, height: 1200 }
          : { width: 1200, height: 900 };
      const bridge = harness(size);
      await bridge.load(jpeg(1200, 900, orientation, little));
      assert.equal(bridge.events[0].kind, "loaded");
      assert.equal(bridge.events[0].width, size.width);
      assert.equal(bridge.events[0].height, size.height);
      assert.equal(bridge.decoded[0].src, "blob:original");
    });
  }
}

test("PNG with alpha uses the original source without re-encoding", async () => {
  const bridge = harness();
  await bridge.load(png(1200, 900), { type: "image/png" });
  assert.equal(bridge.events[0].kind, "loaded");
  assert.equal(bridge.events[0].width, 1200);
  assert.equal(bridge.events[0].height, 900);
  assert.equal(bridge.decoded[0].src, "blob:original");
});

test("PNG eXIf dimensions use native orientation", async () => {
  const bridge = harness({ width: 900, height: 1200 });
  await bridge.load(png(1200, 900, 6), { type: "image/png" });
  assert.equal(bridge.events[0].kind, "loaded");
  assert.equal(bridge.events[0].width, 900);
  assert.equal(bridge.events[0].height, 1200);
});

test("clearing a file rejected by Elm neither reads nor decodes it", async () => {
  const bridge = harness();
  bridge.receive({ action: "clear" });
  bridge.receive({ action: "decode", token: 1 });
  assert.deepEqual(bridge.events, []);
  assert.deepEqual(bridge.metadata, []);
  assert.equal(bridge.decoded.length, 0);
});

test("metadata cannot allocate pixels until Elm authorizes decoding", async () => {
  for (const [width, height] of [
    [1200, 900],
    [10000, 5000],
    [299, 900],
  ]) {
    const bridge = harness({ authorize: false });
    await bridge.load(jpeg(width, height));
    assert.equal(bridge.metadata[0].width, width);
    assert.equal(bridge.metadata[0].height, height);
    assert.equal(bridge.decoded.length, 0);
    assert.deepEqual(bridge.events, []);
    bridge.receive({ action: "release", token: 1 });
    bridge.receive({ action: "decode", token: 1 });
    assert.equal(bridge.decoded.length, 0);
    assert.deepEqual(bridge.revoked, []);
  }
});

test("corrupt metadata reports a read failure for Elm to explain", async () => {
  const bridge = harness();
  await bridge.load(new ArrayBuffer(32));
  assert.equal(bridge.events[0].kind, "failed");
  assert.equal(bridge.events[0].token, 1);
  assert.equal(bridge.decoded.length, 0);
  assert.deepEqual(bridge.metadata, []);
});

test("decoder failure revokes the candidate URL", async () => {
  const bridge = harness({
    decode: () => Promise.reject(new Error("Corrupt")),
  });
  await bridge.load(jpeg(1200, 900));
  assert.equal(bridge.events[0].kind, "failed");
  assert.deepEqual(bridge.revoked, ["blob:original"]);
});

test("native dimensions are reported for Elm to validate orientation", async () => {
  const bridge = harness();
  await bridge.load(jpeg(1200, 900, 6));
  assert.equal(bridge.events[0].kind, "loaded");
  assert.equal(bridge.events[0].width, 900);
  assert.equal(bridge.events[0].height, 1200);
  assert.equal(bridge.events[0].naturalWidth, 1200);
  assert.equal(bridge.events[0].naturalHeight, 900);
});

test("duplicate authorization decodes a source only once", async () => {
  const bridge = harness();
  await bridge.load(jpeg(1200, 900));
  bridge.receive({ action: "decode", token: 1 });
  await new Promise(setImmediate);
  assert.equal(bridge.decoded.length, 1);
  assert.equal(bridge.events.length, 1);
});

test("abandoned metadata read cannot authorize a released source", async () => {
  let complete;
  const bridge = harness();
  await bridge.load(jpeg(1200, 900), {
    arrayBuffer: () => new Promise((resolve) => (complete = resolve)),
  });
  bridge.receive({ action: "release", token: 1 });
  complete(jpeg(1200, 900));
  await new Promise(setImmediate);
  assert.deepEqual(bridge.metadata, []);
  assert.deepEqual(bridge.events, []);
  assert.equal(bridge.decoded.length, 0);
});

test("abandoned pending decode cannot restore a released source", async () => {
  let complete;
  const bridge = harness({
    decode: () => new Promise((resolve) => (complete = resolve)),
  });
  await bridge.load(jpeg(1200, 900));
  bridge.receive({ action: "release", token: 1 });
  complete();
  await new Promise(setImmediate);
  assert.deepEqual(bridge.events, []);
  assert.deepEqual(bridge.revoked, ["blob:original"]);
  assert.equal(bridge.decoded[0].src, "");
});

test("accepted Back abandons pending decode immediately", async () => {
  let complete;
  const bridge = harness({
    decode: () => new Promise((resolve) => (complete = resolve)),
  });
  await bridge.load(jpeg(1200, 900));
  bridge.receive({ action: "navigate", dirty: false, url: "/recipe/123" });
  complete();
  await new Promise(setImmediate);
  assert.deepEqual(bridge.events, []);
  assert.deepEqual(bridge.revoked, ["blob:original"]);
  assert.deepEqual(bridge.navigations, ["/recipe/123"]);
});

test("declined discard keeps pending source and navigation unchanged", async () => {
  let complete;
  const bridge = harness({
    confirm: false,
    decode: () => new Promise((resolve) => (complete = resolve)),
  });
  await bridge.load(jpeg(1200, 900));
  bridge.receive({ action: "navigate", dirty: true, url: "/recipe/123" });
  complete();
  await new Promise(setImmediate);
  assert.equal(bridge.events[0].kind, "loaded");
  assert.deepEqual(bridge.revoked, []);
  assert.deepEqual(bridge.navigations, []);
});
