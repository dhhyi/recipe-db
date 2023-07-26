import {
  AllRecipesQueryDocument,
  CreateRecipeMutationDocument,
  DeleteInspirationsForTestingDocument,
  DeleteRecipesForTestingDocument,
  RecipeByIdWithInspirationQueryDocument,
  UpdateRecipeMutationDocument,
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
          inspirations: ["https://example.com", "https://google.com"],
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

  it.each([[null], [[]]])(
    "should be able to remove inspirations from recipe by sending %s",
    async (val) => {
      const createOperation = await executeOperation(
        CreateRecipeMutationDocument,
        {
          value: {
            name: "test",
            inspirations: ["https://example.com"],
          },
        }
      );
      expect(createOperation).toHaveProperty("createRecipe.id");
      const getOperationBefore = await executeOperation(
        RecipeByIdWithInspirationQueryDocument,
        {
          id: createOperation.createRecipe.id,
        }
      );
      expect(getOperationBefore).toHaveProperty(
        "recipe.inspirations",
        expect.any(Array)
      );
      expect(getOperationBefore.recipe.inspirations).toHaveLength(1);

      const deleteOperation = await executeOperation(
        UpdateRecipeMutationDocument,
        {
          id: createOperation.createRecipe.id,
          value: {
            inspirations: val,
          },
        }
      );
      expect(deleteOperation).toHaveProperty("updateRecipe.id");
      const getOperationAfter = await executeOperation(
        RecipeByIdWithInspirationQueryDocument,
        {
          id: createOperation.createRecipe.id,
        }
      );
      expect(getOperationAfter).toHaveProperty(
        "recipe.inspirations",
        expect.any(Array)
      );
      expect(getOperationAfter.recipe.inspirations).toHaveLength(0);
    }
  );
});
