export const identityHtml =
  '<header-component auth-role="anonymous" maintenance></header-component>';

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
        maintenance: true,
        myCapabilities: { role: "anonymous", canManageRecipes: false },
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
