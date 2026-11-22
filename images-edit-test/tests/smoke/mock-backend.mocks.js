export const graphqlMocks = [
  {
    query: `mutation ($recipeId: ID!, $file: Upload!, $crop: ImageCropInput!) {
      addImage(recipeId: $recipeId, file: $file, crop: $crop) {
        url thumbUrl size width height
      }
    }`,
    variables: {
      recipeId: "test-recipe",
      file: { name: "test.png", type: "image/png", size: 3 },
      crop: { x: 0, y: 0, width: 1, height: 1 },
    },
    response: {
      data: {
        addImage: {
          url: "/images/test.png",
          thumbUrl: "/images/test-thumb.png",
          size: 3,
          width: 1,
          height: 1,
        },
      },
    },
  },
];
