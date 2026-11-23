export const identityHtml =
  '<header-component auth-role="owner"></header-component>';

export const graphqlMocks = [
  {
    query: `query {
      maintenance
      myCapabilities { role canManageImages }
    }`,
    variables: {},
    response: {
      data: {
        maintenance: false,
        myCapabilities: { role: "owner", canManageImages: true },
      },
    },
  },
  {
    query: `query {
      recipe(id: "test-recipe") { name images { id thumbUrl } }
    }`,
    variables: {},
    response: {
      data: {
        recipe: {
          name: "Testrezept",
          images: [{ id: "image-1", thumbUrl: "/images/test-thumb.png" }],
        },
      },
    },
  },
];
