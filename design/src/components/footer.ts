import { LitElement, html } from "lit";
import { customElement } from "lit/decorators.js";

@customElement("footer-component")
export class FooterComponent extends LitElement {
  protected createRenderRoot() {
    return this;
  }

  render() {
    return html`
      <hr />
      <footer class="mb-3 text-center">
        <a
          href="https://github.com/dhhyi/recipe-db/blob/main/README.md"
          class="secondary"
          >GitHub</a
        >
        <span class="px-2" style="color: var(--pico-muted-border-color);"
          >|</span
        >
        <a href="/design/" class="secondary">Design</a>
      </footer>
    `;
  }
}
