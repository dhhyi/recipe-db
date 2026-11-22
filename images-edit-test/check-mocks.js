import { globSync, readFileSync } from "node:fs";
import { buildSchema } from "graphql";
import { validateMock } from "./mock-validation.js";

const schema = buildSchema(
  readFileSync(new URL("./recipe-db.graphqls", import.meta.url), "utf8"),
);
let count = 0;
for (const file of globSync("tests/**/*.mocks.js", {
  cwd: new URL(".", import.meta.url),
})) {
  const { graphqlMocks } = await import(new URL(file, import.meta.url));
  if (!Array.isArray(graphqlMocks)) {
    throw new Error(`${file} must export its test-specific graphqlMocks array`);
  }
  for (const mock of graphqlMocks) {
    validateMock(schema, mock);
    count += 1;
  }
}
console.log(`Validated ${count} test-specific GraphQL mocks.`);
