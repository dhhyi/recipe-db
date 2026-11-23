import { pngFile } from "../png.js";

export const identityHtml =
  '<header-component auth-role="owner"></header-component>';

const image = (n) => ({ id: `image-${n}`, thumbUrl: `/images/thumb-${n}.png` });
const [a, b, c] = [image(1), image(2), image(3)];
const metadata = (item) => ({
  id: item.id,
  url: item.thumbUrl.replace("thumb-", "full-"),
  thumbUrl: item.thumbUrl,
  size: 1234,
  width: 1200,
  height: 900,
});
const galleryRead = (recipeId, ...responses) => ({
  query: `query {
    recipe(id: "${recipeId}") { name images { id thumbUrl } }
  }`,
  variables: {},
  responses: responses.map((images) => ({
    data: { recipe: { name: "Testrezept", images } },
  })),
});
const reorder = (recipeId, images, responses) => ({
  query: `mutation ($recipeId: ID!, $imageIds: [ID!]!) {
    reorderImages(recipeId: $recipeId, imageIds: $imageIds) {
      id url thumbUrl size width height
    }
  }`,
  variables: { recipeId, imageIds: images.map((item) => item.id) },
  responses,
});

export const images = { a, b, c };

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
  // Three rows: the server applies the write but reports a concurrently changed default.
  galleryRead("three-images", [c, a, b], [b, c, a]),
  reorder(
    "three-images",
    [a, b, c],
    [{ data: { reorderImages: [a, b, c].map(metadata) } }],
  ),
  // Two rows: a rejected write, then a lost write that the server committed.
  galleryRead("two-images", [a, b], [a, b], [b, a]),
  reorder(
    "two-images",
    [b, a],
    [
      {
        errors: [
          {
            message: "Image collection changed",
            extensions: { code: "image-order-conflict" },
          },
        ],
      },
    ],
  ),
];

export const imageMocks = Object.fromEntries(
  [a, b, c].map((item, index) => [
    item.thumbUrl,
    { contentType: "image/png", body: pngFile(4 + index, 3).buffer },
  ]),
);
