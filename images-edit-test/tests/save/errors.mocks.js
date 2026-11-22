import { pngFile } from "../png.js";

export const identityHtml =
  '<header-component auth-role="owner"></header-component>';

export const source = pngFile(800, 450);
export const defaultCrop = { x: 100, y: 0, width: 600, height: 450 };
// Minimum size moved to the bottom-right corner; both drags clamp, so it is viewport-independent.
export const crop = { x: 500, y: 225, width: 300, height: 225 };
const existing = { id: "existing", thumbUrl: "/images/existing-thumb.png" };
const saved = { id: "saved", thumbUrl: "/images/saved-thumb.png" };

export const outage = {
  errors: [
    {
      // GraphQL could not connect to the images service, e.g. during a restart.
      message: "images service is unavailable",
      extensions: {
        code: "service-unavailable",
        status: 503,
        service: "images",
      },
    },
  ],
};

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
      { data: { recipe: { name: "Testrezept", images: [existing] } } },
      { data: { recipe: { name: "Testrezept", images: [saved, existing] } } },
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
      outage,
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

export const images = { existing, saved };

export const imageMocks = {
  "/images/existing-thumb.png": {
    contentType: "image/png",
    body: pngFile(8, 6).buffer,
  },
  "/images/saved-thumb.png": {
    contentType: "image/png",
    body: pngFile(4, 3).buffer,
  },
};
