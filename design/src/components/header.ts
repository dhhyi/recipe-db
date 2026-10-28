import { LitElement, html, nothing } from "lit";
import { customElement, property } from "lit/decorators.js";
import { unsafeSVG } from "lit/directives/unsafe-svg.js";
import bannerSvg from "../assets/banner.svg?raw";

@customElement("header-component")
export class HeaderComponent extends LitElement {
  @property({ attribute: "auth-role" })
  authRole = "";

  @property({ type: Boolean, attribute: "auth-unavailable" })
  authUnavailable = false;

  protected createRenderRoot() {
    // drop stale render output restored e.g. from htmx history cache
    this.replaceChildren();
    return this;
  }

  render() {
    return html`
      <header
        style="background-color: var(--pico-background-color);"
        class="px-2 py-1 sticky top-0 z-10"
      >
        <nav class="flex items-center justify-between gap-2">
          <a href="/" hx-boost="true">
            <span style="color: var(--pico-h1-color)" class="contents *:h-8"
              >${unsafeSVG(bannerSvg)}</span
            >
          </a>
          ${
            this.authUnavailable
              ? html`<span role="status"
                  >Anmeldung derzeit nicht verfügbar.</span
                >`
              : this.authRole
                ? html`<a
                    class="secondary"
                    href=${
                      this.authRole === "anonymous"
                        ? "/oauth2/start?rd=%2F"
                        : "/oauth2/sign_out?rd=%2F"
                    }
                    data-tooltip=${
                      this.authRole === "anonymous" ? nothing : this.authRole
                    }
                    data-placement="bottom"
                    >${
                      this.authRole === "anonymous" ? "Anmelden" : "Abmelden"
                    }</a
                  >`
                : null
          }
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
