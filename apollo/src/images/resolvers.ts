import GraphQLUpload from "graphql-upload/GraphQLUpload.mjs";
import { type FileUpload } from "graphql-upload/Upload.mjs";

import {
  type MutationResolvers,
  type RecipeResolvers,
} from "../generated/graphql.js";

import { type ImagesContext } from "./context.js";

async function streamToBuffer(stream): Promise<Buffer> {
  const chunks = [];
  return await new Promise((resolve, reject) => {
    stream.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
    stream.on("error", (err) => {
      reject(err);
    });
    stream.on("end", () => {
      resolve(Buffer.concat(chunks));
    });
  });
}

const Mutation: MutationResolvers<ImagesContext> = {
  deleteImagesForTesting: async (_, __, { imagesAPI }) => {
    return await imagesAPI.deleteImagesForTesting();
  },

  setImage: async (_, { file, recipeId }, { imagesAPI }) => {
    const { createReadStream, mimetype } = await (file as Promise<FileUpload>);

    const stream = createReadStream();
    const content = await streamToBuffer(stream);

    return await imagesAPI.uploadImage(recipeId, mimetype, content);
  },
};

const Recipe: RecipeResolvers<ImagesContext> = {
  image: async (parent, _, { imagesAPI }) => {
    return await imagesAPI.getImageMetadata(parent.id);
  },
};

export const resolvers = {
  Upload: GraphQLUpload,
  Mutation,
  Recipe,
};
