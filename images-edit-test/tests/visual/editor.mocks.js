import { readFileSync } from "node:fs";

const asset = (name) =>
  readFileSync(new URL(`./assets/${name}`, import.meta.url));

export const source = {
  name: "milchreis.png",
  mimeType: "image/png",
  buffer: asset("milchreis.png"),
};

export const capabilities = Object.fromEntries(
  ["anonymous", "member", "owner"].map((role) => [
    role,
    {
      query: `query {
        maintenance
        myCapabilities { role canManageImages }
      }`,
      variables: {},
      response: {
        data: {
          maintenance: false,
          myCapabilities: { role, canManageImages: role === "owner" },
        },
      },
    },
  ]),
);

const recipeQuery = `query {
  recipe(id: "test-recipe") { name images { id thumbUrl } }
}`;

export const recipes = {
  true: {
    query: recipeQuery,
    variables: {},
    response: {
      data: {
        recipe: {
          name: "Milchreis",
          images: [
            { id: "image-b", thumbUrl: "/images/image-b-thumb.png" },
            { id: "milchreis", thumbUrl: "/images/milchreis-thumb.png" },
          ],
        },
      },
    },
  },
  false: {
    query: recipeQuery,
    variables: {},
    response: {
      data: { recipe: { name: "Milchreis", images: null } },
      errors: [
        {
          message: "images service is unavailable",
          path: ["recipe", "images"],
          extensions: {
            code: "service-unavailable",
            status: 503,
            service: "images",
          },
        },
      ],
    },
  },
};

export const imageMocks = Object.fromEntries(
  ["image-b", "milchreis"].map((name) => [
    `/images/${name}-thumb.png`,
    { contentType: "image/png", body: asset(`${name}.png`) },
  ]),
);

export const graphqlMocks = [
  ...Object.values(capabilities),
  ...Object.values(recipes),
];
