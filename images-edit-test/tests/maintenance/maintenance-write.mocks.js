import { defaultCrop, source } from "../save/errors.mocks.js";

export const identityHtml =
  '<header-component auth-role="owner"></header-component>';

export const graphqlMocks = [
  {
    query: `query {
      maintenance
      myCapabilities { role canManageImages }
    }`,
    variables: {},
    response: {
      data: {
        maintenance: false,
        myCapabilities: { role: "owner", canManageImages: true },
      },
    },
  },
  {
    query: `query {
      recipe(id: "test-recipe") { name images { id thumbUrl } }
    }`,
    variables: {},
    response: { data: { recipe: { name: "Testrezept", images: [] } } },
  },
  {
    query: `mutation ($recipeId: ID!, $file: Upload!, $crop: ImageCropInput!) {
      addImage(recipeId: $recipeId, file: $file, crop: $crop) {
        url thumbUrl size width height
      }
    }`,
    variables: {
      recipeId: "test-recipe",
      file: {
        name: source.name,
        type: source.mimeType,
        size: source.buffer.length,
      },
      crop: defaultCrop,
    },
    response: {
      errors: [
        {
          message: "maintenance active",
          extensions: { code: "maintenance-mode", status: 503 },
        },
      ],
    },
  },
];
