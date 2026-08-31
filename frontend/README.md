# Frontend

For pages that are mostly static, [Astro](https://astro.build/) is used for speedy serving and caching.

Astro offers [plugins](https://docs.astro.build/en/guides/integrations-guide/#official-integrations) for different languages for components, which this project tries out.

As most parts of any Astro page can be pre-rendered and cached and rerendered when the data changes, there are plans to add a cache purging solution from backend to frontend later (Message Queue, Websocket).
