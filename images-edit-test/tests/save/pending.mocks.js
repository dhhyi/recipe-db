import {
  defaultCrop,
  graphqlMocks as errorMocks,
  identityHtml,
  imageMocks,
  images,
  source,
} from "./errors.mocks.js";

export { identityHtml, imageMocks, images, source };

const [capabilities, galleryReads, { responses, ...upload }] = errorMocks;

export const graphqlMocks = [
  capabilities,
  galleryReads,
  {
    ...upload,
    variables: { ...upload.variables, crop: defaultCrop },
    response: responses.at(-1),
  },
];
