import type { GraphQLError } from "graphql";

import type { Query } from "../generated/graphql";

export class Custom404Error extends Error {}

function is404(error: GraphQLError): boolean {
  const response = error.extensions?.response as {
    status: number;
    body: { message: string };
  };
  return response?.status === 404;
}

function firstMessage(error: GraphQLError): string {
  const response = error.extensions?.response as { body: { message: string } };
  return response?.body?.message ?? error.message;
}

export async function fetchGraphQL<R extends Query>(
  query: string,
  variables: Record<string, any> | undefined = undefined
): Promise<R> {
  const url =
    typeof window === "undefined" ? "http://traefik/graphql" : "/graphql";
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query, variables: variables ?? undefined }),
  });

  const json = await response.json();
  if (json.errors) {
    if (json.errors.length === 1 && is404(json.errors[0])) {
      throw new Custom404Error(firstMessage(json.errors[0]));
    }
    throw new Error(JSON.stringify(json.errors));
  }

  return json.data;
}
