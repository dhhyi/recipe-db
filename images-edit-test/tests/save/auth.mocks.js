import {
  defaultCrop,
  graphqlMocks as errorMocks,
  identityHtml,
  imageMocks,
  images,
  source,
} from "./errors.mocks.js";

export { identityHtml, imageMocks, images, source };

export const returnDocument =
  "<!doctype html><title>Rezept</title><h1>Testrezept</h1>";

const [capabilities, , { responses, ...upload }] = errorMocks;

export const graphqlMocks = [
  capabilities,
  {
    query: `query {
      recipe(id: "test-recipe") { name images { id thumbUrl } }
    }`,
    variables: {},
    response: {
      data: { recipe: { name: "Testrezept", images: [images.existing] } },
    },
  },
  {
    ...upload,
    variables: { ...upload.variables, crop: defaultCrop },
    response: {
      errors: [
        {
          // GraphQL rejects an expired or invalid bearer token before execution.
          message: "Invalid credentials",
          extensions: { status: 401, code: "invalid-credentials" },
        },
      ],
    },
  },
];
