import { pngFile } from "../png.js";

export const identityHtml =
  '<header-component auth-role="owner"></header-component>';

export const smallSource = pngFile(300, 225);

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
    response: {
      data: {
        recipe: {
          name: "Testrezept",
          images: [{ id: "image-1", thumbUrl: "/images/test-thumb.png" }],
        },
      },
    },
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
        name: smallSource.name,
        type: smallSource.mimeType,
        size: smallSource.buffer.length,
      },
      crop: { x: 0, y: 0, width: 300, height: 225 },
    },
    response: {
      data: {
        addImage: {
          url: "/images/upscaled.png",
          thumbUrl: "/images/upscaled-thumb.png",
          size: 1234,
          width: 648,
          height: 486,
        },
      },
    },
  },
];

export const imageMocks = {
  "/images/test-thumb.png": {
    contentType: "image/png",
    body: pngFile(4, 3).buffer,
  },
};
