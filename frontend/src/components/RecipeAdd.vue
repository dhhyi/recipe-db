<script setup lang="ts">
import { ref } from "vue";
import VueFeather from "vue-feather";

import {
  EditServicesOnline,
  EditServicesOnlineQuery,
} from "../generated/graphql";
import { fetchGraphQL } from "../shared/fetch-data";

const recipesEditAvailable = ref(false);

fetchGraphQL<EditServicesOnlineQuery>(EditServicesOnline).then((data) => {
  recipesEditAvailable.value = !!data.recipeEdit;
});
</script>

<template>
  <a v-if="recipesEditAvailable" href="/edit/new" class="flex gap-2 my-2">
    <vue-feather type="plus-square" size="24"></vue-feather>
    <span>Rezept hinzufügen</span>
  </a>
</template>
