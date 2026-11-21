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
    operationName: "ServiceOnline",
    query: `query ServiceOnline {
      inspirationsOnline: isServiceOnline(name: "inspirations")
    }`,
    variables: {},
    response: { data: { inspirationsOnline: false } },
  },
];
