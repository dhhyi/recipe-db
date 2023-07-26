import { type TypedDocumentNode } from "@graphql-typed-document-node/core";
import axios from "axios";
import { type ExecutionResult, print } from "graphql";

function prettyError(error: {
  message: string;
  extensions?: { response?: { body?: { message?: string }; url?: string } };
}): string {
  const serviceName = error.extensions?.response?.url?.split("/")[3];

  return (
    error.message +
    (error.extensions?.response?.body?.message
      ? `: ${error.extensions.response.body.message}`
      : "") +
    (serviceName ? ` (service: ${serviceName})` : "")
  );
}

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
    if (data.errors.length === 1) throw new Error(prettyError(data.errors[0]));
    throw new Error(JSON.stringify(data.errors, null, 2));
  }
  return data.data;
}
