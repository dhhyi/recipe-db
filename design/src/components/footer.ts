import { LitElement, html } from "lit";
import { customElement } from "lit/decorators.js";

@customElement("footer-component")
export class FooterComponent extends LitElement {
  protected createRenderRoot() {
    return this;
  }

  render() {
    return html`
      <footer
        class="mt-8 border-t py-3 text-center text-sm"
        style="color: var(--pico-muted-color);"
      >
        <a href="https://github.com/dhhyi/recipe-db/blob/main/README.md"
          >GitHub</a
        >
        <span class="px-2">|</span>
        <a href="/design/">Design</a>
      </footer>
    `;
  }
}
