import { RESTDataSource } from "@apollo/datasource-rest";
import { type GraphQLError } from "graphql";

import { addHandler } from "../handlers.js";

export class InspirationsAPI extends RESTDataSource {
  constructor() {
    super();
    this.baseURL = process.env.REST_ENDPOINT + "/inspirations/";

    addHandler("inspirations", async (id: string, data: string[]) => {
      if (data?.length) {
        await this.setInspirations(id, data);
      } else {
        await this.get(id)
          .then(async () => await this.delete(id))
          .catch((err: GraphQLError) => {
            const response = err.extensions?.response as { status: number };
            if (response?.status !== 404) {
              throw err;
            }
          });
      }
    });
  }

  async deleteInspirationsForTesting(): Promise<boolean> {
    return await this.delete("").then(() => {
      return true;
    });
  }

  async getInspirations(id: string): Promise<string[]> {
    return await this.get(id).catch((err: GraphQLError) => {
      const response = err.extensions?.response as { status: number };
      if (response?.status === 404) {
        return [];
      }
      throw err;
    });
  }

  async setInspirations(id: string, inspirations: string[]): Promise<boolean> {
    return await this.put(id, {
      body: JSON.stringify(inspirations),
    }).then(() => true);
  }
}
