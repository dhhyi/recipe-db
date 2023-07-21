<script setup lang="ts">
import VueFeather from "vue-feather";

import type { Recipe } from "../generated/graphql";

type Props = { recipe: Recipe };
defineProps<Props>();
</script>

<template>
  <template v-if="recipe.inspirations?.length">
    <h2 class="h2">Inspiriert von:</h2>
    <ul>
      <li
        v-for="link in recipe.inspirations"
        :key="link.canonical"
        class="py-2 pl-4"
      >
        <a
          :href="link.canonical"
          target="_blank"
          :title="link.description"
          class="flex items-center text-xl"
        >
          <div class="mr-4">
            <vue-feather
              v-if="!link.canonical && !link.favicon"
              type="cloud-off"
              size="32"
            ></vue-feather>
            <img v-else-if="link.favicon" :src="link.favicon" width="32" />
            <vue-feather v-else type="external-link" size="32"></vue-feather>
          </div>
          {{ link.title || link.canonical }}
        </a>
      </li>
    </ul>
  </template>
</template>
