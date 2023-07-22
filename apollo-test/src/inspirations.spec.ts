import {
  AllRecipesQueryDocument,
  CreateRecipeMutationDocument,
  DeleteInspirationsForTestingDocument,
  DeleteRecipesForTestingDocument,
  RecipeByIdWithInspirationQueryDocument,
  SetInspirationsMutationDocument,
} from "./generated/graphql";
import { executeOperation } from "./helpers";

describe("recipes", () => {
  beforeEach(async () => {
    await executeOperation(DeleteRecipesForTestingDocument);
    await executeOperation(DeleteInspirationsForTestingDocument);
  });

  it("should have no recipe", async () => {
    expect(await executeOperation(AllRecipesQueryDocument))
      .toMatchInlineSnapshot(`
      {
        "recipes": [],
      }
    `);
  });

  it("should have a recipe with inspirations after adding one", async () => {
    const createOperation = await executeOperation(
      CreateRecipeMutationDocument,
      {
        value: {
          name: "test",
        },
      }
    );
    expect(createOperation).toMatchInlineSnapshot(
      { createRecipe: { id: expect.any(String) } },
      `
      {
        "createRecipe": {
          "id": Any<String>,
          "name": "test",
        },
      }
    `
    );

    const setInspirationsOperation = await executeOperation(
      SetInspirationsMutationDocument,
      {
        id: createOperation.createRecipe.id,
        inspirations: ["https://example.com", "https://google.com"],
      }
    );

    expect(setInspirationsOperation).toMatchInlineSnapshot(`
      {
        "setInspirations": true,
      }
    `);

    expect(
      await executeOperation(RecipeByIdWithInspirationQueryDocument, {
        id: createOperation.createRecipe.id,
      })
    ).toMatchInlineSnapshot(`
      {
        "recipe": {
          "inspirations": [
            {
              "extracted": {
                "canonical": "https://example.com",
                "description": null,
                "favicon": null,
                "title": "Example Domain",
              },
              "url": "https://example.com",
            },
            {
              "extracted": {
                "canonical": "https://google.com",
                "description": null,
                "favicon": "https://google.com/favicon.ico",
                "title": "Google",
              },
              "url": "https://google.com",
            },
          ],
          "name": "test",
        },
      }
    `);
  });
});
