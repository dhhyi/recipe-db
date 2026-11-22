import { pngFile } from "../png.js";

export const identityHtml =
  '<header-component auth-role="owner"></header-component>';

export const source = pngFile(800, 450);
export const crop = { x: 100, y: 0, width: 600, height: 450 };

export const graphqlMocks = [
  {
    query: `query {
      myCapabilities { role canManageImages }
    }`,
    variables: {},
    response: {
      data: { myCapabilities: { role: "owner", canManageImages: true } },
    },
  },
  {
    query: `query {
      recipe(id: "test-recipe") { name images { id thumbUrl } }
    }`,
    variables: {},
    responses: [
      { data: { recipe: { name: "Testrezept", images: [] } } },
      {
        data: {
          recipe: {
            name: "Testrezept",
            images: [{ id: "saved", thumbUrl: "/images/saved-thumb.png" }],
          },
        },
      },
    ],
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
      crop,
    },
    responses: [
      {
        errors: [
          {
            message: "Invalid crop rectangle",
            extensions: { code: "invalid-crop", status: 400, field: "crop" },
          },
        ],
      },
      {
        data: {
          addImage: {
            url: "/images/saved.png",
            thumbUrl: "/images/saved-thumb.png",
            size: 1234,
            width: 648,
            height: 486,
          },
        },
      },
    ],
  },
];

export const imageMocks = {
  "/images/saved-thumb.png": {
    contentType: "image/png",
    body: pngFile(4, 3).buffer,
  },
};
