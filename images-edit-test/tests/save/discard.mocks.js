import {
  defaultCrop,
  graphqlMocks as errorMocks,
  identityHtml,
  imageMocks,
  images,
  outage,
  source,
} from "./errors.mocks.js";

export { identityHtml, imageMocks, images, source };

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
    response: outage,
  },
];
