<script>
  import { RatingByRecipeId } from "../generated/graphql";
  import { fetchGraphQL } from "../shared/fetch-data";

  export let id;

  async function fetchRating() {
    const response = await fetchGraphQL(RatingByRecipeId, { id: id });
    return response.rating;
  }
</script>

<div class="rating">
  {#await fetchRating()}
    <p>...loading</p>
  {:then value}
    <div>
      <span>Rating: </span><span class="font-bold">{value?.average}</span>
    </div>
    <div>
      <span>Number of ratings: </span><span class="font-bold"
        >{value?.count}</span
      >
    </div>
  {:catch error}
    <p style="color: red">{error.message}</p>
  {/await}
</div>
