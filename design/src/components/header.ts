import { LitElement, html } from "lit";
import { customElement } from "lit/decorators.js";
import { unsafeSVG } from "lit/directives/unsafe-svg.js";
import bannerSvg from "../assets/banner.svg?raw";

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
        <nav>
          <a href="/">
            <span style="color: var(--pico-h1-color)" class="contents *:h-8"
              >${unsafeSVG(bannerSvg)}</span
            >
          </a>
        </nav>
        <div
          aria-hidden="true"
          class="absolute left-0 right-0 top-full"
          style="height: 20px; background: linear-gradient(to bottom, var(--pico-background-color), transparent); pointer-events: none;"
        ></div>
      </header>
    `;
  }
}
