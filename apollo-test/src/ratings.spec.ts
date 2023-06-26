import {
  DeleteForTestingDocument,
  RateMutationDocument,
  RatingByIdQueryDocument,
} from "./generated/graphql";
import { executeOperation } from "./helpers";

describe("ratings", () => {
  beforeEach(async () => {
    await executeOperation(DeleteForTestingDocument);
  });

  it("should have no rating", async () => {
    expect(await executeOperation(RatingByIdQueryDocument, { id: "1" }))
      .toMatchInlineSnapshot(`
      {
        "rating": {
          "average": 0,
          "count": 0,
        },
      }
    `);
  });

  it("should execute rate", async () => {
    expect(
      await executeOperation(RateMutationDocument, {
        id: "1",
        rating: 2,
        login: "test",
      })
    ).toMatchInlineSnapshot(`
      {
        "rate": 2,
      }
    `);
  });

  it("should have rating after multiple rates", async () => {
    await executeOperation(RateMutationDocument, {
      id: "1",
      rating: 2,
      login: "test1",
    });
    await executeOperation(RateMutationDocument, {
      id: "1",
      rating: 3,
      login: "test2",
    });
    await executeOperation(RateMutationDocument, {
      id: "1",
      rating: 5,
      login: "test3",
    });

    expect(await executeOperation(RatingByIdQueryDocument, { id: "1" }))
      .toMatchInlineSnapshot(`
      {
        "rating": {
          "average": 3.5,
          "count": 3,
        },
      }
    `);
  });
});
