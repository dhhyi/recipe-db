<script setup lang="ts">
import VueFeather from "vue-feather";

import type { ExtractedLink, Recipe } from "../generated/graphql";

type Props = { recipe: Recipe };
const props = defineProps<Props>();

type Link = Pick<
  ExtractedLink,
  "title" | "canonical" | "description" | "inlinedFavicon"
>;

const links = (props.recipe.inspirations
  ?.map((link) =>
    link.extracted === null ? { title: link.url } : link.extracted,
  )
  ?.filter((x) => !!x) ?? []) as Link[];
</script>

<template>
  <template v-if="links.length">
    <h2 class="h2">Inspiriert von:</h2>
    <ul>
      <li v-for="link in links" :key="link.canonical" class="py-2 pl-4">
        <a
          :href="link.canonical"
          target="_blank"
          :title="link.description"
          class="flex items-center text-xl"
        >
          <div class="mr-4">
            <vue-feather
              v-if="!link.canonical && !link.inlinedFavicon"
              type="cloud-off"
              size="32"
            ></vue-feather>
            <img
              v-else-if="link.inlinedFavicon"
              :src="link.inlinedFavicon"
              width="32"
            />
            <vue-feather v-else type="external-link" size="32"></vue-feather>
          </div>
          {{ link.title || link.canonical }}
        </a>
      </li>
    </ul>
  </template>
</template>
