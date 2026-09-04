import { LitElement, html } from "lit";
import { customElement } from "lit/decorators.js";

@customElement("header-component")
export class HeaderComponent extends LitElement {
  protected createRenderRoot() {
    return this;
  }

  render() {
    return html`
      <header
        class="p-2 sticky top-0 z-10"
        style="background-color: var(--pico-background-color);"
      >
        <a class="flex flex-row gap-2" href="/">
          <img height class="h-8 pb-2" src="/design/chefs-hat.svg" alt="" />
          <h1>Rezeptdatenbank</h1>
        </a>
      </header>
    `;
  }
}
