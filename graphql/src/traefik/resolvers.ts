import { type QueryResolvers } from "../generated/graphql.js";

import { type TraefikAPI } from "./api.js";
import { type TraefikContext } from "./context.js";

function trimmedName(value: { name: string; provider: string }): string {
  return value.name.replace(value.provider, "").replace(/@$/, "");
}

const entryPoints = process.env.TRAEFIK_ENTRYPOINTS?.split(",") || [];

async function getOnlineServices(traefikAPI: TraefikAPI): Promise<string[]> {
  const services = await traefikAPI.getServices();
  const routers = await traefikAPI.getRouters();

  const onlineServices = services
    .filter((service) =>
      Object.values(service.serverStatus || {}).some(
        (status) => status === "UP",
      ),
    )
    .map(trimmedName);
  return routers
    .filter((router) =>
      router.entryPoints.some((ep) => entryPoints.includes(ep)),
    )
    .filter((router) => onlineServices.includes(router.service))
    .map(trimmedName);
}

const Query: QueryResolvers<TraefikContext> = {
  onlineServices: async (_parent, _args, { traefikAPI }) => {
    return await getOnlineServices(traefikAPI);
  },

  isServiceOnline: async (_parent, { name }, { traefikAPI }) => {
    const onlineServices = await getOnlineServices(traefikAPI);
    return onlineServices.includes(name);
  },

  allServicesOnline: async (_parent, { names }, { traefikAPI }) => {
    const onlineServices = await getOnlineServices(traefikAPI);
    return names.every((name) => onlineServices.includes(name));
  },
};

export const resolvers = {
  Query,
};
