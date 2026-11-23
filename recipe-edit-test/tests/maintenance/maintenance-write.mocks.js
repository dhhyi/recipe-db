import { graphqlMocks as saveMocks } from "../save/error-retry.mocks.js";

export const identityHtml =
  '<header-component auth-role="owner"></header-component>';

export const graphqlMocks = saveMocks.map((mock) =>
  mock.operationName === "UpdateRecipe"
    ? {
        ...mock,
        responses: [
          {
            data: { updateRecipe: null },
            errors: [
              {
                message: "maintenance active",
                extensions: { code: "maintenance-mode", status: 503 },
              },
            ],
          },
        ],
      }
    : mock,
);
