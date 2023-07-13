/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ["./src/**/*.{astro,html,js,jsx,md,mdx,svelte,ts,tsx,vue}"],
  theme: {
    extend: {},
    screens: {
      sm: "640px",
      md: "768px",
      lg: "1024px",
    },
  },
  plugins: [
    function ({ addComponents, theme }) {
      addComponents({
        h1: {
          padding: theme("spacing.4"),
          margin: "auto",
          fontSize: theme("fontSize.3xl"),
          fontWeight: theme("fontWeight.bold"),
        },
        h2: {
          padding: theme("spacing.3"),
          margin: "auto",
          fontSize: theme("fontSize.2xl"),
          fontWeight: theme("fontWeight.bold"),
        },
        h3: {
          padding: theme("spacing.2"),
          margin: "auto",
          fontSize: theme("fontSize.xl"),
          fontWeight: theme("fontWeight.bold"),
        },
      });
    },
  ],
};
