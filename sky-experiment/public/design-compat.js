// Sky 0.29.12 injects an unlayered reset even for App.web / Std.Html.
// Keep it below the shared design without copying or overriding design rules.
const resets = [...document.head.querySelectorAll("style")].filter((style) =>
  style.textContent.startsWith(
    "*,*::before,*::after{box-sizing:border-box}html,body{",
  ),
);
if (resets.length !== 1) {
  throw new Error(
    "Sky reset changed: review the design compatibility bridge before upgrading Sky.",
  );
}
// The design sets typography on html; even a layered body font overrides
// inheritance, so let body inherit it instead of Sky's font and line-height.
// resets[0].textContent = `@layer sky-runtime {${resets[0].textContent} body { font: inherit; }}`;
document.documentElement.lang = "de";
