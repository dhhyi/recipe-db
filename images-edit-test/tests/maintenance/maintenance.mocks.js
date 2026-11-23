export const identityHtml =
  '<header-component auth-role="anonymous" maintenance></header-component>';

export const graphqlMocks = [
  {
    query: `query {
      maintenance
      myCapabilities { role canManageImages }
    }`,
    variables: {},
    response: {
      data: {
        maintenance: true,
        myCapabilities: { role: "anonymous", canManageImages: false },
      },
    },
  },
  {
    query: `query {
      recipe(id: "test-recipe") { name images { id thumbUrl } }
    }`,
    variables: {},
    response: { data: { recipe: { name: "Testrezept", images: [] } } },
  },
];
