export const identityHtml =
  '<header-component auth-role="owner"></header-component>';

export const returnDocument =
  "<!doctype html><title>Return destination</title>";

export const graphqlMocks = [
  {
    operationName: "MyCapabilities",
    query: `query MyCapabilities {
      myCapabilities {
        role
        canManageRecipes
      }
    }`,
    variables: {},
    response: {
      data: {
        myCapabilities: { role: "owner", canManageRecipes: true },
      },
    },
  },
  {
    operationName: "ServiceOnline",
    query: `query ServiceOnline {
      inspirationsOnline: isServiceOnline(name: "inspirations")
    }`,
    variables: {},
    response: { data: { inspirationsOnline: false } },
  },
  {
    operationName: "RecipeById",
    query: `query RecipeById($id: ID!) {
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
    }`,
    variables: { id: "recipe-1" },
    response: {
      data: {
        recipe: {
          name: "Soup",
          method: "Mix",
          inspirations: [],
          ingredients: [],
        },
        inspirationsOnline: false,
      },
    },
  },
];
