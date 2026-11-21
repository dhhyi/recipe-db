const assert = require("node:assert/strict");
const fs = require("node:fs");
const test = require("node:test");
const vm = require("node:vm");

const html = fs.readFileSync("index.html", "utf8");
const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/gi)]
  .map((match) => match[1])
  .find((source) => source.includes("Elm.Main.init"));

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
  const input = {
    value: "selected",
    files: [],
    focus: (options) => (input.focusOptions = options),
  };
  const galleryEvents = [];
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
      visibilityState: options.visibilityState ?? "visible",
      startViewTransition: options.startViewTransition,
      querySelector: (selector) =>
        selector === "header-component"
          ? header
          : selector === "main.image-editor"
            ? { dispatchEvent: (event) => galleryEvents.push(event) }
            : {},
      getElementById: () => input,
      addEventListener: (name, listener) =>
        documentListeners.set(name, listener),
    },
    window: {
      matchMedia: () => ({ matches: options.reducedMotion ?? false }),
      location: {
        href: "http://recipe.test/images/123",
        assign: (url) => navigations.push(url),
      },
      confirm: (message) =>
        typeof options.confirm === "function"
          ? options.confirm(message)
          : (options.confirm ?? true),
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
    CSS: { supports: () => options.transitionSupported ?? true },
    requestAnimationFrame: (callback) => setImmediate(callback),
    CustomEvent: class {
      constructor(type, options) {
        this.type = type;
        this.detail = options.detail;
      }
    },
    DataView,
    Uint8Array,
  });
  return {
    events,
    galleryEvents,
    metadata,
    revoked,
    decoded,
    header,
    input,
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

test("gallery reconciliation falls back when transitions cannot run", () => {
  for (const options of [
    {},
    { startViewTransition: () => assert.fail(), reducedMotion: true },
    { startViewTransition: () => assert.fail(), visibilityState: "hidden" },
    { startViewTransition: () => assert.fail(), transitionSupported: false },
  ]) {
    const bridge = harness(options);
    bridge.receive({ action: "transition-gallery", token: 7 });
    assert.equal(bridge.galleryEvents[0].type, "apply-gallery");
    assert.equal(bridge.galleryEvents[0].detail, 7);
  }
});

test("gallery reconciliation happens inside the view transition update", async () => {
  let update;
  const bridge = harness({
    startViewTransition: (options) => {
      assert.deepEqual(Array.from(options.types), ["gallery-change"]);
      update = options.update;
    },
  });
  bridge.receive({ action: "transition-gallery", token: 4 });
  assert.equal(bridge.galleryEvents.length, 0);
  await update();
  assert.equal(bridge.galleryEvents[0].type, "apply-gallery");
  assert.equal(bridge.galleryEvents[0].detail, 4);
});

test("gallery focus does not scroll the page", async () => {
  const bridge = harness();
  bridge.receive({ action: "focus-without-scroll", id: "move-down-image" });
  await new Promise(setImmediate);
  assert.equal(bridge.input.focusOptions.preventScroll, true);
});

test("saving locks shared header navigation and clean state removes unload listener", () => {
  const bridge = harness();
  bridge.receive({ action: "guard", dirty: true, saving: true });
  assert.equal(bridge.header.inert, true);
  bridge.header.inert = false;
  bridge.dispatch("htmx:afterSwap");
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

test("gallery writes block in-app navigation without adding an unload dialog", () => {
  const bridge = harness();
  bridge.receive({ action: "guard", dirty: false, saving: true });
  assert.equal(bridge.header.inert, true);
  assert.equal(bridge.click("http://recipe.test/"), true);
  assert.equal(bridge.windowListeners.has("beforeunload"), false);
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
    closest: (selector) =>
      selector === "[data-handle]" ? target : selector === ".crop-stage" ? stage : null,
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

test("gallery pointer uses stable list capture, ignores clicks and cancels safely", () => {
  const bridge = harness();
  let shift = 0;
  let captured = false;
  const rows = ["a", "b", "c"].map((id, index) => ({
    dataset: { galleryId: id },
    getBoundingClientRect: () => ({ top: index * 100 + shift, height: 100 }),
  }));
  const list = {
    querySelectorAll: () => rows,
    setPointerCapture() { captured = true; },
    hasPointerCapture: () => captured,
    releasePointerCapture() { captured = false; },
  };
  const handle = {
    dataset: { enabled: "true", galleryHandle: "b" },
    closest: (selector) => selector === ".gallery-list" ? list : null,
  };
  const target = { closest: (selector) => selector === "[data-gallery-handle]" ? handle : null };
  const event = {
    target, isPrimary: true, button: 0, pointerId: 7,
    clientX: 20, clientY: 150, preventDefault() {},
  };
  bridge.dispatch("pointerdown", event);
  assert.equal(captured, true);
  shift = 60;
  bridge.dispatch("pointerup", event);
  assert.deepEqual(bridge.events.map((e) => e.kind), ["gallery-drag-start", "gallery-drag-end"]);
  assert.equal(bridge.events[1].cancelled, false);

  shift = 0;
  bridge.dispatch("pointerdown", event);
  shift = 60;
  bridge.dispatch("pointermove", { ...event, clientY: 40 });
  assert.equal(bridge.events.at(-1).index, 0);
  bridge.dispatch("keydown", { key: "Escape", preventDefault() {} });
  assert.equal(bridge.events.at(-1).cancelled, true);
  assert.equal(captured, false);

  bridge.dispatch("pointerdown", event);
  bridge.dispatch("pointercancel", event);
  assert.equal(bridge.events.at(-1).cancelled, true);
  const count = bridge.events.length;
  bridge.dispatch("pointerdown", { ...event, target: { closest: () => null } });
  assert.equal(bridge.events.length, count);
  handle.dataset.enabled = "false";
  bridge.dispatch("pointerdown", event);
  assert.equal(bridge.events.length, count);
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

test("native image confirmation returns the opaque ID and gallery session", () => {
  let prompt;
  const bridge = harness({
    confirm: (message) => {
      prompt = message;
      return true;
    },
  });
  bridge.receive({
    action: "confirm-delete",
    imageId: "opaque/id?with#reserved",
    session: 7,
    message: "Das erste Bild löschen?",
  });
  assert.equal(prompt, "Das erste Bild löschen?");
  assert.equal(
    JSON.stringify(bridge.events[0]),
    JSON.stringify({
      kind: "delete-confirmation",
      imageId: "opaque/id?with#reserved",
      session: 7,
      accepted: true,
    }),
  );
});

test("dismissed native image confirmation returns no accepted deletion", () => {
  const bridge = harness({ confirm: false });
  bridge.receive({
    action: "confirm-delete",
    imageId: "opaque-image-id",
    session: 9,
    message: "Dieses Bild löschen?",
  });
  assert.equal(
    JSON.stringify(bridge.events[0]),
    JSON.stringify({
      kind: "delete-confirmation",
      imageId: "opaque-image-id",
      session: 9,
      accepted: false,
    }),
  );
});
