import { RESTDataSource } from "@apollo/datasource-rest";

interface TraefikRouter {
  name: string;
  service: string;
  provider: string;
  entryPoints: string[];
}

interface TraefikService {
  name: string;
  provider: string;
  serverStatus: Record<string, "UP" | "DOWN">;
}

export class TraefikAPI extends RESTDataSource {
  constructor() {
    super();
    this.baseURL = process.env.REST_ENDPOINT + "/api/http/";
  }

  async getRouters(): Promise<TraefikRouter[]> {
    return await this.get("routers");
  }

  async getServices(): Promise<TraefikService[]> {
    return await this.get("services");
  }
}
