<script setup lang="ts">
import { ref } from "vue";
import VueFeather from "vue-feather";

import {
  EditServicesOnline,
  EditServicesOnlineQuery,
  Recipe,
} from "../generated/graphql";
import { fetchGraphQL } from "../shared/fetch-data";

const recipesEditAvailable = ref(false);

fetchGraphQL<EditServicesOnlineQuery>(EditServicesOnline).then((data) => {
  recipesEditAvailable.value = !!data.recipeEdit;
});

type Props = { recipe: Recipe };
const props = defineProps<Props>();
</script>

<template>
  <a v-if="recipesEditAvailable" :href="'/edit/' + props.recipe.id">
    <vue-feather type="edit" size="32"></vue-feather>
  </a>
</template>
