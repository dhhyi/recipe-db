import { pngFile } from "../png.js";

export const identityHtml =
  '<header-component auth-role="owner"></header-component>';

const first = { id: "image-1", thumbUrl: "/images/thumb-1.png" };
const second = { id: "image-2", thumbUrl: "/images/thumb-2.png" };
const metadata = (image) => ({
  id: image.id,
  url: image.thumbUrl.replace("thumb-", "full-"),
  thumbUrl: image.thumbUrl,
  size: 1234,
  width: 1200,
  height: 900,
});
const gallery = (images) => ({
  data: { recipe: { name: "Testrezept", images } },
});
const reorder = (images) => ({
  query: `mutation ($recipeId: ID!, $imageIds: [ID!]!) {
    reorderImages(recipeId: $recipeId, imageIds: $imageIds) {
      id url thumbUrl size width height
    }
  }`,
  variables: {
    recipeId: "test-recipe",
    imageIds: images.map((image) => image.id),
  },
  response: { data: { reorderImages: images.map(metadata) } },
});

export const images = { first, second };

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
      gallery([first, second]),
      gallery([second, first]),
      gallery([first, second]),
    ],
  },
  reorder([second, first]),
  reorder([first, second]),
];

export const imageMocks = {
  "/images/thumb-1.png": {
    contentType: "image/png",
    body: pngFile(4, 3).buffer,
  },
  "/images/thumb-2.png": {
    contentType: "image/png",
    body: pngFile(8, 6).buffer,
  },
};
