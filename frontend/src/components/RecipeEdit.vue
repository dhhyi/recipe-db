<script setup lang="ts">
import VueFeather from "vue-feather";

import type { Recipe } from "../generated/graphql";

type Props = { recipe: Recipe };
const props = defineProps<Props>();
</script>

<template>
  <a :href="'/edit/' + props.recipe.id">
    <vue-feather type="edit" size="32"></vue-feather>
  </a>
</template>
