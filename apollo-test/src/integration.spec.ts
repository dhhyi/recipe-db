import {
  CreateRecipeMutationDocument,
  DeleteRatingsForTestingDocument,
  DeleteRecipesForTestingDocument,
  IntegrationAllRecipesQueryDocument,
  RateMutationDocument,
} from "./generated/graphql";
import { executeOperation } from "./helpers";

describe("ratings", () => {
  beforeEach(async () => {
    await executeOperation(DeleteRecipesForTestingDocument);
    await executeOperation(DeleteRatingsForTestingDocument);
  });

  it("should be possible to have a recipe without rating", async () => {
    await executeOperation(CreateRecipeMutationDocument, {
      value: { name: "Rice Pudding" },
    });

    expect(await executeOperation(IntegrationAllRecipesQueryDocument))
      .toMatchInlineSnapshot(`
      {
        "recipes": [
          {
            "name": "Rice Pudding",
            "rating": {
              "average": 0,
              "count": 0,
            },
          },
        ],
      }
    `);
  });

  it("should be possible to have a recipe with ratings", async () => {
    const create = await executeOperation(CreateRecipeMutationDocument, {
      value: { name: "Beetroot Soup" },
    });
    expect(create?.createRecipe?.id).toBeTruthy();

    await executeOperation(RateMutationDocument, {
      id: create?.createRecipe?.id,
      login: "user1",
      rating: 5,
    });

    await executeOperation(RateMutationDocument, {
      id: create?.createRecipe?.id,
      login: "user2",
      rating: 4,
    });

    expect(await executeOperation(IntegrationAllRecipesQueryDocument))
      .toMatchInlineSnapshot(`
      {
        "recipes": [
          {
            "name": "Beetroot Soup",
            "rating": {
              "average": 4.5,
              "count": 2,
            },
          },
        ],
      }
    `);
  });
});
