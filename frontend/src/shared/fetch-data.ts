import type { Query } from "../generated/graphql";

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
  if (json.errors) throw new Error(JSON.stringify(json.errors[0].message));

  return json.data;
}
