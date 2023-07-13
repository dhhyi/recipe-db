<script>
  export let average;
  export let count = null;
  export let size = 32;

  const stars = [];
  for (let i = 1; i <= 5; i++) {
    if (i <= average) {
      // full star
      stars.push({ width: size, fill: "orange", viewBox: "0 0 24 24" });
    } else if (i - average < 1) {
      // half filled star
      stars.push({ width: size / 2, fill: "orange", viewBox: "0 0 12 24" });
      // half empty star
      stars.push({ width: size / 2, fill: "none", viewBox: "12 0 12 24" });
    } else {
      // empty star
      stars.push({ width: size, fill: "none", viewBox: "0 0 24 24" });
    }
  }
</script>

<div class="flex">
  {#each stars as star}
    <!-- taken from https://feathericons.com/?query=star -->
    <svg
      xmlns="http://www.w3.org/2000/svg"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      height={size}
      {...star}
    >
      <polygon
        points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"
      />
    </svg>
  {/each}
  {#if typeof count === "number"}
    <span class="font-bold text-xl">({count})</span>
  {/if}
</div>
