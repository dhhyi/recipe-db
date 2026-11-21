export const identityHtml =
  '<header-component auth-role="owner"></header-component>';

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
    variables: { id: "missing-recipe" },
    response: {
      data: { recipe: null, inspirationsOnline: true },
    },
  },
];
