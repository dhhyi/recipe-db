import { test, expect, graphql } from "./fixtures.js";

test.use({ trace: "off", resetApplicationData: false });

async function withRecipe(owner, name, use) {
  const { createRecipe } = await graphql(
    owner.api,
    "mutation($value: RecipeInput!) { createRecipe(value: $value) { id name } }",
    { value: { name } },
  );
  try {
    await use(createRecipe);
  } finally {
    await graphql(owner.api, "mutation($id: ID!) { deleteRecipe(id: $id) }", {
      id: createRecipe.id,
    });
  }
}

async function rating(identity, id, includeVote = true) {
  const data = await graphql(
    identity.api,
    `query($id: ID!) { rating(id: $id) { average count${includeVote ? " myRating" : ""} } }`,
    { id },
  );
  return data.rating;
}

async function rate(identity, id, value) {
  return graphql(
    identity.api,
    "mutation($id: ID!, $rating: Int!) { rate(id: $id, rating: $rating) { average count myRating } }",
    { id, rating: value },
  );
}

test("concurrent members and repeated votes preserve exact aggregates", async ({
  authContexts,
  ownerIdentity,
}) => {
  const first = await authContexts.memberOne();
  const second = await authContexts.memberTwo();
  const anonymous = await authContexts.anonymous();
  await withRecipe(
    ownerIdentity,
    "Access concurrent ratings",
    async ({ id }) => {
      expect(await rating(first, id)).toEqual({
        average: 0,
        count: 0,
        myRating: null,
      });
      expect((await rating(second, id)).myRating).toBeNull();
      await rate(first, id, 5);
      await rate(first, id, 3);
      expect(await rating(first, id)).toEqual({
        average: 3,
        count: 1,
        myRating: 3,
      });
      expect((await rating(second, id)).myRating).toBeNull();
      await Promise.all([
        ...Array.from({ length: 4 }, () => rate(first, id, 2)),
        ...Array.from({ length: 4 }, () => rate(second, id, 4)),
      ]);
      expect(await rating(first, id)).toEqual({
        average: 3,
        count: 2,
        myRating: 2,
      });
      expect(await rating(second, id)).toEqual({
        average: 3,
        count: 2,
        myRating: 4,
      });
      expect(await rating(anonymous, id, false)).toEqual({
        average: 3,
        count: 2,
      });
    },
  );
});

test("denied own-vote fields preserve public GraphQL data and error paths", async ({
  authContexts,
  ownerIdentity,
}) => {
  const anonymous = await authContexts.anonymous();
  const member = await authContexts.memberOne();
  await withRecipe(
    ownerIdentity,
    "Access partial GraphQL",
    async ({ id, name }) => {
      const response = await anonymous.api.post("/graphql", {
        data: {
          query:
            "query($id: ID!) { publicRecipe: recipe(id: $id) { name aggregate: rating { average count own: myRating } } }",
          variables: { id },
        },
      });
      expect(response.status()).toBe(200);
      const result = await response.json();
      expect(result.data).toEqual({
        publicRecipe: { name, aggregate: { average: 0, count: 0, own: null } },
      });
      expect(result.errors).toHaveLength(1);
      expect(result.errors[0].path).toEqual([
        "publicRecipe",
        "aggregate",
        "own",
      ]);
      expect(result.errors[0].extensions).toMatchObject({
        code: "authentication-required",
        status: 401,
      });
      expect(await rating(member, id)).toEqual({
        average: 0,
        count: 0,
        myRating: null,
      });
    },
  );
});
