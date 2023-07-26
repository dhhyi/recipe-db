import {
  AllRecipesQueryDocument,
  CreateRecipeMutationDocument,
  DeleteRecipeMutationDocument,
  DeleteRecipesForTestingDocument,
  RecipeByIdQueryDocument,
  UpdateRecipeMutationDocument,
} from "./generated/graphql";
import { executeOperation } from "./helpers";

describe("recipes", () => {
  beforeEach(async () => {
    await executeOperation(DeleteRecipesForTestingDocument);
  });

  it("should have no recipe", async () => {
    expect(await executeOperation(AllRecipesQueryDocument))
      .toMatchInlineSnapshot(`
      {
        "recipes": [],
      }
    `);
  });

  it("should have a recipe after adding one", async () => {
    const createOperation = await executeOperation(
      CreateRecipeMutationDocument,
      {
        value: {
          name: "test",
          method: "cook it",
          ingredients: [
            { name: "ingredient", amount: 1 },
            { name: "opt", optional: true },
          ],
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
      await executeOperation(RecipeByIdQueryDocument, {
        id: createOperation.createRecipe.id,
      })
    ).toMatchInlineSnapshot(
      {
        recipe: {
          id: expect.any(String),
          ingredients: expect.any(Array),
          method: expect.any(String),
        },
      },
      `
      {
        "recipe": {
          "id": Any<String>,
          "ingredients": Any<Array>,
          "method": Any<String>,
          "name": "test",
        },
      }
    `
    );

    const allRecipes = await executeOperation(AllRecipesQueryDocument);
    expect(allRecipes?.recipes).toHaveLength(1);
  });

  it("should be able to edit a recipe", async () => {
    const create = await executeOperation(CreateRecipeMutationDocument, {
      value: { name: "test" },
    });
    expect(create).toBeTruthy();
    expect(create?.createRecipe.id).toBeTruthy();

    const beforeEdit = await executeOperation(RecipeByIdQueryDocument, {
      id: create.createRecipe.id,
    });
    expect(beforeEdit?.recipe).toHaveProperty("name", "test");
    expect(beforeEdit?.recipe).toHaveProperty("method", null);

    const edit = await executeOperation(UpdateRecipeMutationDocument, {
      id: create.createRecipe.id,
      value: { name: "test2", method: "cook it" },
    });
    expect(edit).toBeTruthy();

    const afterEdit = await executeOperation(RecipeByIdQueryDocument, {
      id: create.createRecipe.id,
    });
    expect(afterEdit?.recipe).toHaveProperty("name", "test2");
    expect(afterEdit?.recipe).toHaveProperty("method", "cook it");
  });

  it("should be able to delete a recipe", async () => {
    const create = await executeOperation(CreateRecipeMutationDocument, {
      value: { name: "test" },
    });
    expect(create).toBeTruthy();
    expect(create?.createRecipe.id).toBeTruthy();

    let allRecipes = await executeOperation(AllRecipesQueryDocument);
    expect(allRecipes?.recipes).toHaveLength(1);

    const deleteOperation = await executeOperation(
      DeleteRecipeMutationDocument,
      {
        id: create.createRecipe.id,
      }
    );
    expect(deleteOperation).toMatchInlineSnapshot(`
      {
        "deleteRecipe": true,
      }
    `);

    allRecipes = await executeOperation(AllRecipesQueryDocument);
    expect(allRecipes?.recipes).toHaveLength(0);
  });

  it("should not be able to delete an unknown recipe", async () => {
    const deleteOperation = await executeOperation(
      DeleteRecipeMutationDocument,
      {
        id: "unknown",
      }
    );
    expect(deleteOperation).toMatchInlineSnapshot(`
      {
        "deleteRecipe": false,
      }
    `);
  });

  it.each([[""], [null]])(
    "should not be able to add a recipe with '%s' name",
    async (val) => {
      try {
        await executeOperation(CreateRecipeMutationDocument, {
          value: {
            name: val,
          },
        });
        throw new Error("should have thrown");
      } catch (error) {
        expect(error?.message).toEqual(
          "400: Bad Request: Missing field value for name (service: recipes)"
        );
      }
    }
  );

  it.each([[""], [null]])(
    "should not be able to change the name of recipe to '%s'",
    async (val) => {
      const create = await executeOperation(CreateRecipeMutationDocument, {
        value: { name: "test" },
      });
      expect(create).toBeTruthy();
      expect(create?.createRecipe.id).toBeTruthy();

      try {
        await executeOperation(UpdateRecipeMutationDocument, {
          id: create.createRecipe.id,
          value: { name: val },
        });
        throw new Error("should have thrown");
      } catch (error) {
        expect(error?.message).toEqual(
          "400: Bad Request: Missing field value for name (service: recipes)"
        );
      }
    }
  );
});
