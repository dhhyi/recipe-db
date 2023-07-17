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
    class="fixed flex w-full bg-white shadow-md items-center justify-between flex-wrap m-auto top-0"
  >
    <div class="container mx-auto">
      <a class="mx-4 my-4 flex items-center" href="/"
        ><img src="/assets/chefs-hat.svg" alt="Startseite" width="30" />
        <span class="mx-4 text-2xl hidden sm:block">Rezeptsammlung</span>
      </a>
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
