<script setup lang="ts">
import { ref } from "vue";
import VueFeather from "vue-feather";

import {
  EditServicesOnline,
  EditServicesOnlineQuery,
  Recipe,
} from "../generated/graphql";
import { fetchGraphQL } from "../shared/fetch-data";

const editAvailable = ref({
  any: false,
  recipe: false,
  image: false,
});

fetchGraphQL<EditServicesOnlineQuery>(EditServicesOnline).then((data) => {
  editAvailable.value = {
    any: !!data.recipeEdit || !!data.imageEdit,
    recipe: !!data.recipeEdit,
    image: !!data.imageEdit,
  };
});

type Props = { recipe: Recipe };
const props = defineProps<Props>();

const isChecked = ref(false);
function toggle() {
  isChecked.value = !isChecked.value;
}
</script>

<template>
  <div class="flex gap-4">
    <a v-if="isChecked" :href="'/edit/' + props.recipe.id">
      <vue-feather
        v-if="editAvailable?.recipe"
        type="edit-3"
        size="32"
      ></vue-feather>
    </a>
    <a v-if="isChecked" :href="'/images-edit/' + props.recipe.id">
      <vue-feather
        v-if="editAvailable?.image"
        type="image"
        size="32"
      ></vue-feather>
    </a>
    <a v-if="editAvailable?.any" @click.prevent="toggle">
      <vue-feather v-if="isChecked" type="x" size="32"></vue-feather>
      <vue-feather v-else type="edit" size="32"></vue-feather>
    </a>
  </div>
</template>
