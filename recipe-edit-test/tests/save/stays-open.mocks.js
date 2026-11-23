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
  {
    operationName: "UpdateRecipe",
    query: `mutation UpdateRecipe($id: ID!, $input: RecipeInput!) {
      updateRecipe(id: $id, value: $input) {
        id
      }
    }`,
    variables: {
      id: "recipe-1",
      input: {
        name: "Soup updated",
        method: "Mix",
        ingredients: [
          { amount: "200", unit: "g", name: "Fine salt", optional: false },
        ],
        inspirations: [],
      },
    },
    responses: [{ data: { updateRecipe: { id: "recipe-1" } } }],
  },
];
