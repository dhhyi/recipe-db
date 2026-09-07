import type { RecipeInput } from "./generated/graphql.js";

type HandlerFunction<T> = (id: string, data: T) => Promise<any>;

type RecipeExternalFields = keyof Omit<
  RecipeInput,
  "name" | "method" | "ingredients"
>;

const handlers: Partial<Record<RecipeExternalFields, HandlerFunction<any>>> =
  {};

export type RecipeHandlers = typeof handlers;

export const handlersContext = {
  handlers,
};

export function addHandler<T extends RecipeExternalFields>(
  name: T,
  handler: HandlerFunction<RecipeInput[T]>,
): void {
  handlers[name] = handler;
}

export type HandlersContext = typeof handlersContext;
