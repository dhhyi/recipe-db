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
        style="background-color: var(--pico-background-color);"
        class="px-2 py-1 sticky top-0 z-10 relative"
      >
        <a class="flex flex-row items-center gap-2" href="/">
          <img height class="h-8" src="/design/chefs-hat.svg" alt="" />
          <h1 class="m-0!">Rezeptdatenbank</h1>
        </a>
        <div
          aria-hidden="true"
          class="absolute left-0 right-0 top-full"
          style="height: 20px; background: linear-gradient(to bottom, var(--pico-background-color), transparent); pointer-events: none;"
        ></div>
      </header>
    `;
  }
}
