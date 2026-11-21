export const identityHtml =
  '<header-component auth-role="owner"></header-component>';

export const savedMethod = [
  "Milch langsam erhitzen und einmal aufkochen.",
  "Reis einstreuen und gründlich verrühren.",
  "Bei kleiner Hitze weiterköcheln lassen.",
  "Zwischendurch regelmäßig umrühren.",
  "Zum Schluss mit Zimt abschmecken.",
  "Vor dem Servieren kurz ruhen lassen.",
].join("\n\n");

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
          method: savedMethod,
          inspirations: [],
          ingredients: [],
        },
        inspirationsOnline: true,
      },
    },
  },
];
