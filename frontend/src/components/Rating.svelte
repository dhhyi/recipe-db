<script>
  import { AlertTriangleIcon } from "svelte-feather-icons";

  import { RatingByRecipeId } from "../generated/graphql";
  import { fetchGraphQL } from "../shared/fetch-data";

  import RatingStars from "./RatingStars.svelte";

  export let id;
  export let size = 32;
  export let count = true;

  async function fetchRating() {
    const response = await fetchGraphQL(RatingByRecipeId, { id: id });
    return response.rating;
  }
</script>

<div>
  {#await fetchRating()}
    <p>...loading</p>
  {:then rating}
    <RatingStars
      average={rating.average}
      count={count && rating.count}
      {size}
    />
  {:catch error}
    <span title="Bewertungen sind nicht verfuegbar ({error.message})">
      <AlertTriangleIcon size="32" class="warning-icon" />
    </span>
  {/await}
</div>
