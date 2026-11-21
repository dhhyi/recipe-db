export const identityHtml =
  '<header-component auth-role="owner"></header-component>';

const updateRecipe = `mutation UpdateRecipe($id: ID!, $input: RecipeInput!) {
  updateRecipe(id: $id, value: $input) {
    id
  }
}`;

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
  {
    operationName: "UpdateRecipe",
    query: updateRecipe,
    variables: {
      id: "recipe-1",
      input: { name: "", method: "Mix", ingredients: [] },
    },
    response: {
      data: { updateRecipe: null },
      errors: [
        {
          message: "Missing field value for name",
          extensions: { code: "required-field", field: "name", status: 422 },
        },
      ],
    },
  },
  {
    operationName: "UpdateRecipe",
    query: updateRecipe,
    variables: {
      id: "recipe-1",
      input: { name: "Soup corrected", method: "Mix", ingredients: [] },
    },
    response: { data: { updateRecipe: { id: "recipe-1" } } },
  },
];
