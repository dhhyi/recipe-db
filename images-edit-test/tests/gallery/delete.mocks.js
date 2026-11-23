import { pngFile } from "../png.js";

export const identityHtml =
  '<header-component auth-role="owner"></header-component>';

const image = (n) => ({ id: `image-${n}`, thumbUrl: `/images/thumb-${n}.png` });
const [a, b] = [image(1), image(2)];
const galleryRead = (recipeId, ...responses) => ({
  query: `query {
    recipe(id: "${recipeId}") { name images { id thumbUrl } }
  }`,
  variables: {},
  responses: responses.map((images) => ({
    data: { recipe: { name: "Testrezept", images } },
  })),
});
const deletion = (recipeId, item, deleted = true) => ({
  query: `mutation ($recipeId: ID!, $imageId: ID!) {
    deleteImage(recipeId: $recipeId, imageId: $imageId)
  }`,
  variables: { recipeId, imageId: item.id },
  response: { data: { deleteImage: deleted } },
});

export const images = { a, b };

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
  galleryRead("sole-image", [a], []),
  deletion("sole-image", a),
  galleryRead("delete-first", [a, b], [b]),
  deletion("delete-first", a),
  galleryRead("delete-second", [a, b], [a]),
  deletion("delete-second", b),
  // Another session removed the image before this deletion arrived.
  galleryRead("already-removed", [a], []),
  deletion("already-removed", a, false),
  galleryRead("animated", [a, b], [b]),
  deletion("animated", a),
];

export const imageMocks = Object.fromEntries(
  [a, b].map((item, index) => [
    item.thumbUrl,
    { contentType: "image/png", body: pngFile(4 + index, 3).buffer },
  ]),
);
