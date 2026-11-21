import assert from "node:assert/strict";
import test from "node:test";
import { buildSchema } from "graphql";
import { takeMockResponse, validateMock } from "./mock-validation.js";

const schema = buildSchema(`
  type Query {
    recipes(limit: Int!): [Recipe!]!
  }

  type Recipe {
    id: ID!
    title: String!
    status: Status!
    description: String
  }

  enum Status {
    READY
    DRAFT
  }
`);

const query = `
  query RecipeList($limit: Int!) {
    recipes(limit: $limit) {
      key: id
      ...RecipeFields
    }
  }

  fragment RecipeFields on Recipe {
    title
    status
    description
  }
`;

const data = {
  recipes: [{ key: "42", title: "Soup", status: "READY", description: null }],
};

function mock(response, overrides = {}) {
  return {
    operationName: "RecipeList",
    query,
    variables: { limit: 1 },
    response,
    ...overrides,
  };
}

test("validates aliased, fragment-based data and input variables", () => {
  assert.equal(validateMock(schema, mock({ data })), true);
});

test("accepts root null bubbling when an execution error is present", () => {
  assert.equal(
    validateMock(
      schema,
      mock({
        data: null,
        errors: [{ message: "Resolver failed", path: ["recipes", 0, "title"] }],
      }),
    ),
    true,
  );
});

test("accepts partial data with an error at a nullable selected field", () => {
  assert.equal(
    validateMock(
      schema,
      mock({
        data: {
          recipes: [
            {
              key: "42",
              title: "Soup",
              status: "READY",
              description: null,
            },
          ],
        },
        errors: [
          { message: "Resolver failed", path: ["recipes", 0, "description"] },
        ],
      }),
    ),
    true,
  );
});

test("rejects null for a non-null field inside a present parent", () => {
  assert.throws(
    () =>
      validateMock(
        schema,
        mock({
          data: { recipes: null },
          errors: [
            { message: "Resolver failed", path: ["recipes", 0, "title"] },
          ],
        }),
      ),
    /cannot be null/,
  );
});

test("rejects wrong scalar and enum values, missing fields, and extra fields", () => {
  for (const recipe of [
    { key: 42, title: "Soup", status: "READY", description: null },
    { key: "42", title: "Soup", status: "UNKNOWN", description: null },
    { key: "42", title: "Soup" },
    {
      key: "42",
      title: "Soup",
      status: "READY",
      description: null,
      extra: true,
    },
  ]) {
    assert.throws(() =>
      validateMock(schema, mock({ data: { recipes: [recipe] } })),
    );
  }
});

test("validates the operation and required input variables against the schema", () => {
  assert.throws(
    () => validateMock(schema, mock({ data }, { variables: {} })),
    /variables are invalid/,
  );
  assert.throws(
    () =>
      validateMock(
        schema,
        mock(
          { data },
          { query: "query RecipeList { recipes(limit: 1) { id notAField } }" },
        ),
      ),
    /query is not valid/,
  );
});

test("rejects malformed GraphQL response envelopes and errors", () => {
  assert.throws(
    () => validateMock(schema, mock({})),
    /data or non-empty errors/,
  );
  assert.throws(
    () => validateMock(schema, mock({ data, errors: [] })),
    /non-empty array/,
  );
  assert.throws(
    () => validateMock(schema, mock({ data, errors: [{ path: ["recipes"] }] })),
    /with a message/,
  );
  assert.throws(
    () => validateMock(schema, mock({ data, unexpected: true })),
    /not a GraphQL response property/,
  );
});

test("validates every response in a sequence", () => {
  const { response, ...request } = mock({ data });
  assert.equal(
    validateMock(schema, {
      ...request,
      responses: [{ errors: [{ message: "Failed" }] }, response],
    }),
    true,
  );
  assert.throws(
    () => validateMock(schema, { ...request, responses: [response, {}] }),
    /data or non-empty errors/,
  );
  assert.throws(
    () => validateMock(schema, { ...request, responses: [] }),
    /non-empty array/,
  );
  assert.throws(
    () => validateMock(schema, { ...request, response, responses: [response] }),
    /either response or responses/,
  );
});

test("consumes sequential responses and fails explicitly when exhausted", () => {
  const first = { errors: [{ message: "Failed" }] };
  const second = { data };
  const sequence = { operationName: "RecipeList", responses: [first, second] };
  assert.equal(takeMockResponse(sequence), first);
  assert.equal(takeMockResponse(sequence), second);
  assert.throws(() => takeMockResponse(sequence), /responses exhausted/);

  const reusable = { response: second };
  assert.equal(takeMockResponse(reusable), second);
  assert.equal(takeMockResponse(reusable), second);
});
