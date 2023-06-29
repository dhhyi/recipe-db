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
      { recipe: { id: expect.any(String) } },
      `
      {
        "recipe": {
          "id": Any<String>,
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

    const edit = await executeOperation(UpdateRecipeMutationDocument, {
      id: create.createRecipe.id,
      value: { name: "test2" },
    });
    expect(edit).toBeTruthy();

    const recipe = await executeOperation(RecipeByIdQueryDocument, {
      id: create.createRecipe.id,
    });
    expect(recipe?.recipe).toHaveProperty("name", "test2");
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
});
