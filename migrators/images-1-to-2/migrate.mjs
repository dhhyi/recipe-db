import { randomBytes } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const dataDirectory = "/data";
const sourceVersion = 1;
const targetVersion = 2;

function fail(message) {
  throw new Error(message);
}

function regularFile(filePath) {
  let info;
  try {
    info = fs.lstatSync(filePath);
  } catch (error) {
    fail(`cannot inspect ${filePath}: ${error.message}`);
  }
  if (!info.isFile()) {
    fail(`expected a regular file at ${filePath}`);
  }
  return info;
}

function directory(directoryPath) {
  let info;
  try {
    info = fs.lstatSync(directoryPath);
  } catch (error) {
    fail(`cannot inspect ${directoryPath}: ${error.message}`);
  }
  if (!info.isDirectory()) {
    fail(`expected a directory at ${directoryPath}`);
  }
}

function checkVersion(markerPath, expected) {
  regularFile(markerPath);
  let contents;
  try {
    contents = fs.readFileSync(markerPath);
  } catch (error) {
    fail(`cannot read ${markerPath}: ${error.message}`);
  }
  if (!contents.equals(Buffer.from(`${expected}\n`))) {
    fail(`expected storage version ${expected} at ${markerPath}`);
  }
}

function validRecipeId(recipeId) {
  return typeof recipeId === "string" &&
    Buffer.byteLength(recipeId, "utf8") > 0 &&
    Buffer.byteLength(recipeId, "utf8") <= 128 &&
    !recipeId.includes("..") &&
    !/[/\\\u0000-\u001f]/u.test(recipeId);
}

function parseOutputUrl(url, recipeId, thumbnail, manifestPath) {
  if (typeof url !== "string" || !url.startsWith("/public/") ||
      url.includes("?") || url.includes("#")) {
    fail(`invalid public URL in ${manifestPath}`);
  }
  const component = url.slice("/public/".length);
  if (!component || component.includes("/")) {
    fail(`public URL escapes the image directory in ${manifestPath}`);
  }

  let filename;
  try {
    filename = decodeURIComponent(component);
  } catch {
    fail(`invalid encoded filename in ${manifestPath}`);
  }
  if (path.posix.basename(filename) !== filename || filename.includes("\\")) {
    fail(`unsafe output filename in ${manifestPath}`);
  }
  const match = /^(.+)-([0-9a-f]{64})(-thumb)?\.png$/u.exec(filename);
  if (!match || !validRecipeId(match[1]) || match[1] !== recipeId ||
      Boolean(match[3]) !== thumbnail) {
    fail(`output filename does not match recipe ${recipeId} in ${manifestPath}`);
  }
  return { filename, digest: match[2] };
}

function validateEntry(metadata, recipeId, manifestPath, publicDirectory) {
  if (!metadata || Array.isArray(metadata) || typeof metadata !== "object" ||
      metadata.recipeId !== recipeId || !validRecipeId(metadata.recipeId) ||
      typeof metadata.modified !== "string" ||
      !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}$/u.test(metadata.modified) ||
      !Number.isSafeInteger(metadata.width) ||
      !Number.isSafeInteger(metadata.height) ||
      !((metadata.width === 650 && metadata.height === 488) ||
        (metadata.width === 648 && metadata.height === 486)) ||
      !Number.isSafeInteger(metadata.size) || metadata.size <= 0 ||
      typeof metadata.url !== "string" ||
      typeof metadata.thumbUrl !== "string") {
    fail(`invalid version-1 metadata in ${manifestPath}`);
  }
  const modified = new Date(`${metadata.modified}Z`);
  if (!Number.isFinite(modified.valueOf()) ||
      modified.toISOString().slice(0, -1) !== metadata.modified) {
    fail(`invalid modified timestamp in ${manifestPath}`);
  }

  const normal = parseOutputUrl(
    metadata.url, recipeId, false, manifestPath);
  const thumbnail = parseOutputUrl(
    metadata.thumbUrl, recipeId, true, manifestPath);
  const normalInfo = regularFile(path.join(publicDirectory, normal.filename));
  regularFile(path.join(publicDirectory, thumbnail.filename));
  if (normalInfo.size !== metadata.size) {
    fail(`normal image size does not match metadata in ${manifestPath}`);
  }
  return normal.digest;
}

function syncDirectory(directoryPath) {
  const descriptor = fs.openSync(directoryPath, "r");
  try {
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
}

function atomicWrite(targetPath, contents) {
  const directoryPath = path.dirname(targetPath);
  const mode = regularFile(targetPath).mode & 0o777;
  const temporaryPath = path.join(
    directoryPath,
    `.${path.basename(targetPath)}.pending-${process.pid}-${randomBytes(8).toString("hex")}`,
  );
  let descriptor;
  try {
    descriptor = fs.openSync(temporaryPath, "wx", 0o600);
    fs.writeFileSync(descriptor, contents);
    fs.fchmodSync(descriptor, mode);
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    fs.renameSync(temporaryPath, targetPath);
    syncDirectory(directoryPath);
  } finally {
    if (descriptor !== undefined) {
      fs.closeSync(descriptor);
    }
    try {
      fs.unlinkSync(temporaryPath);
    } catch (error) {
      if (error.code !== "ENOENT") {
        throw error;
      }
    }
  }
}

function preflight(manifestDirectory, publicDirectory) {
  const names = fs.readdirSync(manifestDirectory).sort();
  const manifests = [];
  for (const name of names) {
    const manifestPath = path.join(manifestDirectory, name);
    regularFile(manifestPath);
    if (!name.endsWith(".json")) {
      fail(`unexpected file in manifests directory: ${name}`);
    }
    const recipeId = name.slice(0, -".json".length);
    if (!validRecipeId(recipeId)) {
      fail(`invalid recipe ID in manifest filename: ${name}`);
    }

    let metadata;
    try {
      metadata = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    } catch (error) {
      fail(`cannot parse manifest ${name}: ${error.message}`);
    }
    const digest = validateEntry(
      metadata, recipeId, manifestPath, publicDirectory);
    manifests.push({
      manifestPath,
      recipeId,
      converted: { ...metadata, id: digest },
    });
  }
  return manifests;
}

function validateTarget(manifests, publicDirectory) {
  for (const manifest of manifests) {
    let entries;
    try {
      entries = JSON.parse(fs.readFileSync(manifest.manifestPath, "utf8"));
    } catch (error) {
      fail(`cannot validate converted manifest ${manifest.manifestPath}: ${error.message}`);
    }
    if (!Array.isArray(entries) || entries.length !== 1) {
      fail(`invalid version-2 manifest at ${manifest.manifestPath}`);
    }
    const digest = validateEntry(
      entries[0], manifest.recipeId, manifest.manifestPath, publicDirectory);
    if (entries[0].id !== digest ||
        JSON.stringify(entries[0]) !== JSON.stringify(manifest.converted)) {
      fail(`converted manifest changed metadata at ${manifest.manifestPath}`);
    }
  }
}

function migrate() {
  directory(dataDirectory);
  const markerPath = path.join(dataDirectory, "storage-version");
  checkVersion(markerPath, sourceVersion);
  const publicDirectory = path.join(dataDirectory, "public");
  const manifestDirectory = path.join(dataDirectory, "manifests");
  directory(publicDirectory);
  directory(manifestDirectory);

  const manifests = preflight(manifestDirectory, publicDirectory);
  for (const manifest of manifests) {
    atomicWrite(manifest.manifestPath, `${JSON.stringify([manifest.converted])}\n`);
  }
  validateTarget(manifests, publicDirectory);
  checkVersion(markerPath, sourceVersion);
  atomicWrite(markerPath, `${targetVersion}\n`);
}

try {
  migrate();
} catch (error) {
  console.error(`images 1-to-2 migration failed: ${error.message}`);
  process.exitCode = 1;
}
