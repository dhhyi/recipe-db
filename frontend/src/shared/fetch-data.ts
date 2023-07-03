import { print, type DocumentNode } from "graphql";

import type { Query } from "../generated/graphql";

export async function fetchGraphQL<R extends Query>(
  query: DocumentNode,
  variables: Record<string, any> | undefined = undefined
): Promise<R> {
  const response = await fetch("http://traefik/graphql", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      query: print(query),
      variables: variables ?? undefined,
    }),
  });

  const json = await response.json();
  if (json.errors) throw new Error(JSON.stringify(json.errors[0].message));

  return json.data;
}
