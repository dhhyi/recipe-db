import { type TypedDocumentNode } from "@graphql-typed-document-node/core";
import axios from "axios";
import { type ExecutionResult, print } from "graphql";

export async function executeOperation<TResult, TVariables>(
  operation: TypedDocumentNode<TResult, TVariables>,
  ...[variables]: TVariables extends Record<string, never> ? [] : [TVariables]
): Promise<ExecutionResult<TResult>["data"]> {
  const response = await axios.request({
    url: "http://traefik/graphql",
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    data: JSON.stringify({
      query: print(operation),
      variables: variables ?? undefined,
    }),
  });
  const data = response.data;
  if (data.errors) {
    throw data.errors;
  }
  return data.data;
}
