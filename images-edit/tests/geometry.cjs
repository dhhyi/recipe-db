const assert = require("node:assert/strict");
const { Elm } = require("../elm-stuff/geometry-tests.js");
const app = Elm.GeometryTests.init({ flags: null });
const timeout = setTimeout(() => {
  throw new Error("Geometry tests did not report results");
}, 10000);
app.ports.results.subscribe((results) => {
  clearTimeout(timeout);
  for (const { name, passed } of results) assert.equal(passed, true, name);
  console.log(`${results.length} geometry tests passed`);
});
