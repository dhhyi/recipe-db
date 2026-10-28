function fn() {
  var authTokens = java.lang.System.getenv("E2E_AUTH_TOKENS");
  if (!authTokens) {
    throw new Error(
      "GraphQL auth test tokens are missing; run mise run create-auth-test-fixture.",
    );
  }

  var tokens = JSON.parse(authTokens);
  if (!tokens.owner || !tokens.memberOne || !tokens.memberTwo) {
    throw new Error(
      "GraphQL auth test tokens are missing; run mise run create-auth-test-fixture.",
    );
  }

  return {
    ownerAuthorization: "Bearer " + tokens.owner,
    memberOneAuthorization: "Bearer " + tokens.memberOne,
    memberTwoAuthorization: "Bearer " + tokens.memberTwo,
  };
}
