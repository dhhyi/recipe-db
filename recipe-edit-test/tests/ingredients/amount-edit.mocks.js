export const identityHtml =
  '<header-component auth-role="owner"></header-component>';

export const graphqlMocks = [
  {
    operationName: "MyCapabilities",
    query: `query MyCapabilities {
      maintenance
      myCapabilities {
        role
        canManageRecipes
      }
    }`,
    variables: {},
    response: {
      data: {
        maintenance: false,
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
    variables: { id: "recipe-1" },
    response: {
      data: {
        recipe: {
          name: "Soup",
          method: "Mix",
          inspirations: [],
          ingredients: [
            { amount: "200", unit: "g", name: "Salt", optional: false },
          ],
        },
        inspirationsOnline: true,
      },
    },
  },
];
