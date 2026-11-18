import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const image = process.argv[2];
const testId = process.argv[3];
assert.ok(image && testId, "image and test id are required");
const workDirectory = fs.mkdtempSync(path.join(os.tmpdir(), `${testId}-`));
const normalDigest = "a".repeat(64);
const thumbDigest = "b".repeat(64);
let succeeded = false;

function directories(root) {
  fs.mkdirSync(path.join(root, "public"), { recursive: true });
  fs.mkdirSync(path.join(root, "manifests"), { recursive: true });
}

function addManifest(root, recipeId, dimensions = [648, 486]) {
  const normal = Buffer.from(`unchanged normal bytes for ${recipeId}`);
  const thumbnail = Buffer.from(`unchanged thumbnail bytes for ${recipeId}`);
  const normalName = `${recipeId}-${normalDigest}.png`;
  const thumbName = `${recipeId}-${thumbDigest}-thumb.png`;
  fs.writeFileSync(path.join(root, "public", normalName), normal);
  fs.writeFileSync(path.join(root, "public", thumbName), thumbnail);
  const metadata = {
    recipeId,
    width: dimensions[0],
    height: dimensions[1],
    size: normal.length,
    modified: "2026-03-04T05:06:07.890",
    url: `/public/${encodeURIComponent(normalName)}`,
    thumbUrl: `/public/${encodeURIComponent(thumbName)}`,
    preserved: { source: "fixture", sequence: 17 },
  };
  fs.writeFileSync(
    path.join(root, "manifests", `${recipeId}.json`),
    `${JSON.stringify(metadata)}\n`,
  );
  return metadata;
}

function createRoot(name, marker = "1\n") {
  const root = path.join(workDirectory, name);
  fs.mkdirSync(root);
  directories(root);
  if (marker !== null) {
    fs.writeFileSync(path.join(root, "storage-version"), marker);
  }
  return root;
}

function snapshot(root) {
  const result = {};
  function visit(directory, prefix = "") {
    for (const name of fs.readdirSync(directory).sort()) {
      const filePath = path.join(directory, name);
      const relativePath = path.posix.join(prefix, name);
      const info = fs.lstatSync(filePath);
      if (info.isDirectory()) {
        result[relativePath] = "directory";
        visit(filePath, relativePath);
      } else {
        result[relativePath] = fs.readFileSync(filePath).toString("base64");
      }
    }
  }
  visit(root);
  return result;
}

function run(root, name, failMarkerPublication = false) {
  const container = `${testId}-${name}`;
  const args = [
    "run",
    "--rm",
    "--name",
    container,
    "--user",
    `${process.getuid()}:${process.getgid()}`,
    "--network",
    "none",
    "--mount",
    `type=bind,src=${root},dst=/data`,
  ];
  if (failMarkerPublication) {
    args.push(
      "--env",
      "NODE_OPTIONS=--require=/data/fail-marker-publication.cjs",
    );
  }
  args.push(image);
  const result = spawnSync("docker", args, { encoding: "utf8" });
  assert.ifError(result.error);
  return result;
}

function expectSuccess(root, name) {
  const result = run(root, name);
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
}

function expectMigrationFailure(root, name, failMarkerPublication = false) {
  const result = run(root, name, failMarkerPublication);
  assert.notEqual(result.status, 0, `${name} unexpectedly succeeded`);
  assert.match(result.stderr, /images 1-to-2 migration failed/u);
}

try {
  const conversion = createRoot("conversion");
  const old650 = addManifest(conversion, "recipe-650", [650, 488]);
  const old648 = addManifest(conversion, "recipe-648", [648, 486]);
  const orphanName = `recipe-648-${"c".repeat(64)}.png`;
  const orphanBytes = Buffer.from("historical unreferenced output");
  fs.writeFileSync(path.join(conversion, "public", orphanName), orphanBytes);
  const imageFilesBefore = snapshot(path.join(conversion, "public"));
  expectSuccess(conversion, "conversion");
  assert.equal(
    fs.readFileSync(path.join(conversion, "storage-version"), "utf8"),
    "2\n",
  );
  for (const [recipeId, oldMetadata] of [
    ["recipe-650", old650],
    ["recipe-648", old648],
  ]) {
    const entries = JSON.parse(
      fs.readFileSync(
        path.join(conversion, "manifests", `${recipeId}.json`),
        "utf8",
      ),
    );
    assert.equal(entries.length, 1);
    assert.deepEqual(entries[0], { ...oldMetadata, id: normalDigest });
  }
  assert.deepEqual(snapshot(path.join(conversion, "public")), imageFilesBefore);
  assert.equal(
    fs.readFileSync(path.join(conversion, "public", orphanName), "utf8"),
    orphanBytes.toString("utf8"),
  );

  const empty = createRoot("empty");
  expectSuccess(empty, "empty");
  assert.equal(
    fs.readFileSync(path.join(empty, "storage-version"), "utf8"),
    "2\n",
  );
  assert.deepEqual(fs.readdirSync(path.join(empty, "manifests")), []);

  const rejected = [
    [
      "malformed-json",
      (root) => {
        fs.writeFileSync(path.join(root, "manifests", "z-bad.json"), "{");
      },
    ],
    [
      "unsupported-array",
      (root) => {
        fs.writeFileSync(path.join(root, "manifests", "z-bad.json"), "[]\n");
      },
    ],
    [
      "mismatched-recipe-id",
      (root) => {
        const metadata = addManifest(root, "z-bad");
        metadata.recipeId = "other-recipe";
        fs.writeFileSync(
          path.join(root, "manifests", "z-bad.json"),
          JSON.stringify(metadata),
        );
      },
    ],
    [
      "mismatched-output-recipe",
      (root) => {
        const metadata = addManifest(root, "z-bad");
        const mismatchedName = `other-${normalDigest}.png`;
        fs.writeFileSync(path.join(root, "public", mismatchedName), "normal");
        metadata.url = `/public/${mismatchedName}`;
        fs.writeFileSync(
          path.join(root, "manifests", "z-bad.json"),
          JSON.stringify(metadata),
        );
      },
    ],
    [
      "invalid-content-digest",
      (root) => {
        const metadata = addManifest(root, "z-bad");
        const invalidName = `z-bad-${"A".repeat(64)}.png`;
        fs.writeFileSync(path.join(root, "public", invalidName), "normal");
        metadata.url = `/public/${invalidName}`;
        fs.writeFileSync(
          path.join(root, "manifests", "z-bad.json"),
          JSON.stringify(metadata),
        );
      },
    ],
    [
      "symlink-reference",
      (root) => {
        const metadata = addManifest(root, "z-bad");
        const normalPath = path.join(
          root,
          "public",
          `z-bad-${normalDigest}.png`,
        );
        fs.unlinkSync(normalPath);
        fs.symlinkSync(`z-bad-${thumbDigest}-thumb.png`, normalPath);
        fs.writeFileSync(
          path.join(root, "manifests", "z-bad.json"),
          JSON.stringify(metadata),
        );
      },
    ],
    [
      "unsafe-url",
      (root) => {
        const metadata = addManifest(root, "z-bad");
        metadata.url = "/public/../outside.png";
        fs.writeFileSync(
          path.join(root, "manifests", "z-bad.json"),
          JSON.stringify(metadata),
        );
      },
    ],
    [
      "external-url",
      (root) => {
        const metadata = addManifest(root, "z-bad");
        metadata.thumbUrl = "https://example.invalid/image.png";
        fs.writeFileSync(
          path.join(root, "manifests", "z-bad.json"),
          JSON.stringify(metadata),
        );
      },
    ],
    [
      "missing-output",
      (root) => {
        const metadata = addManifest(root, "z-bad");
        fs.unlinkSync(path.join(root, "public", `z-bad-${normalDigest}.png`));
        fs.writeFileSync(
          path.join(root, "manifests", "z-bad.json"),
          JSON.stringify(metadata),
        );
      },
    ],
    [
      "unsupported-dimensions",
      (root) => {
        const metadata = addManifest(root, "z-bad", [640, 480]);
        fs.writeFileSync(
          path.join(root, "manifests", "z-bad.json"),
          JSON.stringify(metadata),
        );
      },
    ],
  ];

  for (const [name, makeInvalid] of rejected) {
    const root = createRoot(name);
    addManifest(root, "a-valid");
    makeInvalid(root);
    const before = snapshot(root);
    expectMigrationFailure(root, name);
    assert.deepEqual(
      snapshot(root),
      before,
      `${name} changed data during preflight`,
    );
    assert.equal(
      fs.readFileSync(path.join(root, "storage-version"), "utf8"),
      "1\n",
    );
  }

  for (const [name, marker] of [
    ["missing-marker", null],
    ["malformed-marker", "one\n"],
    ["unexpected-marker", "3\n"],
    ["already-target", "2\n"],
  ]) {
    const root = createRoot(name, marker);
    const before = snapshot(root);
    expectMigrationFailure(root, name);
    assert.deepEqual(snapshot(root), before, `${name} changed data`);
  }

  const markerFailure = createRoot("marker-failure");
  const oldFirst = addManifest(markerFailure, "first");
  const oldSecond = addManifest(markerFailure, "second");
  fs.writeFileSync(
    path.join(markerFailure, "fail-marker-publication.cjs"),
    `const fs = require("node:fs");
const renameSync = fs.renameSync;
fs.renameSync = function (source, target) {
  if (target === "/data/storage-version") {
    throw new Error("injected marker publication failure");
  }
  return renameSync.call(fs, source, target);
};
`,
  );
  const markerFailurePublic = snapshot(path.join(markerFailure, "public"));
  const failedMarkerPublish = run(markerFailure, "marker-failure", true);
  assert.notEqual(failedMarkerPublish.status, 0);
  assert.match(
    failedMarkerPublish.stderr,
    /injected marker publication failure/u,
  );
  assert.equal(
    fs.readFileSync(path.join(markerFailure, "storage-version"), "utf8"),
    "1\n",
  );
  for (const [recipeId, oldMetadata] of [
    ["first", oldFirst],
    ["second", oldSecond],
  ]) {
    const entries = JSON.parse(
      fs.readFileSync(
        path.join(markerFailure, "manifests", `${recipeId}.json`),
        "utf8",
      ),
    );
    assert.deepEqual(entries, [{ ...oldMetadata, id: normalDigest }]);
  }
  assert.deepEqual(
    snapshot(path.join(markerFailure, "public")),
    markerFailurePublic,
  );
  const uncertainMarkerState = snapshot(markerFailure);
  expectMigrationFailure(markerFailure, "marker-failure-retry");
  assert.deepEqual(snapshot(markerFailure), uncertainMarkerState);

  const uncertain = createRoot("uncertain");
  const partial = addManifest(uncertain, "partial");
  fs.writeFileSync(
    path.join(uncertain, "manifests", "partial.json"),
    `${JSON.stringify([{ ...partial, id: normalDigest }])}\n`,
  );
  const uncertainBefore = snapshot(uncertain);
  expectMigrationFailure(uncertain, "uncertain");
  assert.deepEqual(snapshot(uncertain), uncertainBefore);
  assert.equal(
    fs.readFileSync(path.join(uncertain, "storage-version"), "utf8"),
    "1\n",
  );

  succeeded = true;
  console.log("images 1-to-2 migration container fixtures passed");
} finally {
  if (succeeded) {
    fs.rmSync(workDirectory, { recursive: true, force: true });
  } else {
    console.error(
      `images migration fixture diagnostics retained in ${workDirectory}`,
    );
  }
}
