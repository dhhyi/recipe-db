export const identityHtml =
  '<header-component auth-role="owner"></header-component>';

export const returnDocument = "<!doctype html><title>Ziel</title><h1>Ziel</h1>";

export const graphqlMocks = [
  {
    query: `query {
      myCapabilities { role canManageImages }
    }`,
    variables: {},
    response: {
      data: { myCapabilities: { role: "owner", canManageImages: true } },
    },
  },
  {
    query: `query {
      recipe(id: "test-recipe") { name images { id thumbUrl } }
    }`,
    variables: {},
    response: {
      data: { recipe: { name: "Testrezept", images: [] } },
    },
  },
];
