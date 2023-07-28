import type { GraphQLError } from "graphql";

import type { Query } from "../generated/graphql";

export class Custom404Error extends Error {}

export class ApolloDownError extends Error {}

export class ServerError extends Error {}

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

  try {
    const json = await response.json();
    if (json.errors) {
      if (
        (!json.data ||
          Object.entries(json.data).every(([_, v]) => v === null)) &&
        json.errors.length === 1 &&
        is404(json.errors[0])
      ) {
        throw new Custom404Error(firstMessage(json.errors[0]));
      }
      console.log("QUERY", /([A-Z]\w*)/.exec(query)?.[1], variables ?? {});

      json.errors.forEach((error: GraphQLError) => {
        console.error("ERROR", error.path?.join?.("/"), error.message);
      });
    }

    return json.data;
  } catch (error) {
    if (response.status === 502) {
      throw new ApolloDownError();
    } else if (error instanceof SyntaxError) {
      throw new ServerError("GraphQL server response is not valid JSON.");
    }
    throw error;
  }
}
