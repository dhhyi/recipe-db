<script setup>
import { reactive } from "vue";

let view = reactive({
  atTopOfPage: true,
});

function handleScroll() {
  if (window.scrollY > 0) {
    if (view.atTopOfPage) view.atTopOfPage = false;
  } else {
    if (!view.atTopOfPage) view.atTopOfPage = true;
  }
}

if (typeof window !== "undefined") {
  window.addEventListener("scroll", handleScroll);
}
</script>

<template>
  <nav
    :class="{ scrolled: !view.atTopOfPage }"
    class="fixed flex w-full bg-white shadow-md items-center justify-between flex-wrap p-5 m-auto top-0"
  >
    <div class="container mx-auto">
      <a class="mx-2" href="/">Startseite</a>
    </div>
  </nav>
  <div class="h-16"></div>
</template>

<style scoped>
nav {
  z-index: 10;
}

nav.scrolled {
  @apply shadow-2xl;
}
</style>
