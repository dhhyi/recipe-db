const capabilitiesQuery = `query MyCapabilities {
  myCapabilities {
    role
    canManageRecipes
  }
}`;

const recipeQuery = `query RecipeById($id: ID!) {
  recipe(id: $id) {
    name
    method
    inspirations {
      url
    }
    ingredients {
      amount
      unit
      name
      optional
    }
  }
  inspirationsOnline: isServiceOnline(name: "inspirations")
}`;

const serviceQuery = `query ServiceOnline {
  inspirationsOnline: isServiceOnline(name: "inspirations")
}`;

export const capabilities = Object.fromEntries(
  ["anonymous", "member", "owner"].map((role) => [
    role,
    {
      operationName: "MyCapabilities",
      query: capabilitiesQuery,
      variables: {},
      response: {
        data: {
          myCapabilities: { role, canManageRecipes: role === "owner" },
        },
      },
    },
  ]),
);

export const recipes = Object.fromEntries(
  [true, false].map((online) => [
    String(online),
    {
      operationName: "RecipeById",
      query: recipeQuery,
      variables: { id: "recipe-1" },
      response: {
        data: {
          recipe: {
            name: "E2E Milchreis",
            method:
              "Milchreis und Milch langsam aufkochen.\n\nUnter Rühren garen und mit Salz abschmecken.",
            inspirations: online ? [] : null,
            ingredients: [
              { amount: "200", unit: "g", name: "Milchreis", optional: null },
              { amount: "500", unit: "ml", name: "Milch", optional: null },
              { amount: null, unit: null, name: "Salz", optional: null },
              { amount: null, unit: null, name: "Zimt", optional: true },
            ],
          },
          inspirationsOnline: online,
        },
        ...(online
          ? {}
          : {
              errors: [
                {
                  message: "inspirations service is unavailable",
                  path: ["recipe", "inspirations"],
                  extensions: {
                    code: "service-unavailable",
                    status: 503,
                    service: "inspirations",
                  },
                },
              ],
            }),
      },
    },
  ]),
);

export const services = Object.fromEntries(
  [true, false].map((online) => [
    String(online),
    {
      operationName: "ServiceOnline",
      query: serviceQuery,
      variables: {},
      response: { data: { inspirationsOnline: online } },
    },
  ]),
);

export const graphqlMocks = [
  ...Object.values(capabilities),
  ...Object.values(recipes),
  ...Object.values(services),
];
