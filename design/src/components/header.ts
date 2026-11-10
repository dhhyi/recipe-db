import { LitElement, html } from "lit";
import { customElement, property } from "lit/decorators.js";
import { unsafeSVG } from "lit/directives/unsafe-svg.js";
import bannerSvg from "../assets/banner.svg?raw";

@customElement("header-component")
export class HeaderComponent extends LitElement {
  @property({ attribute: "auth-role" })
  authRole = "";

  @property({ attribute: "auth-name" })
  authName = "";

  @property({ type: Boolean, attribute: "auth-enabled" })
  authEnabled = false;

  protected createRenderRoot() {
    // drop stale render output restored e.g. from htmx history cache
    this.replaceChildren();
    return this;
  }

  private startLogin(event: Event) {
    const link = event.currentTarget;
    if (!(link instanceof HTMLAnchorElement)) return;

    const { origin, pathname, search, hash } = window.location;
    const currentURL = `${pathname}${search}${hash}`;
    let returnTo = "/";
    if (currentURL.startsWith("/") && !currentURL.startsWith("//")) {
      const destination = new URL(currentURL, origin);
      if (destination.origin === origin) returnTo = currentURL;
    }

    const loginURL = new URL("/oauth2/start", origin);
    loginURL.searchParams.set("rd", returnTo);
    link.href = `${loginURL.pathname}${loginURL.search}`;
  }

  private renderAuth() {
    if (!this.authRole || !this.authEnabled) return null;
    if (this.authRole === "anonymous") {
      return html`<ul class="unlist">
        <li>
          <a href="/oauth2/start?rd=%2F" @click=${this.startLogin}>Anmelden</a>
        </li>
      </ul>`;
    }
    return html`<ul class="unlist">
      <li>
        <details class="dropdown">
          <summary>${this.authName || this.authRole}</summary>
          <ul dir="rtl">
            <li><a href="/oauth2/sign_out?rd=%2F">Abmelden</a></li>
          </ul>
        </details>
      </li>
    </ul>`;
  }

  render() {
    return html`
      <header
        style="background-color: var(--pico-background-color);"
        class="px-2 py-1 sticky top-0 z-10"
      >
        <nav class="[--pico-nav-element-spacing-vertical:0]">
          <ul class="unlist">
            <li>
              <a href="/" hx-boost="true" class="align-top">
                <span style="color: var(--pico-h1-color)" class="contents *:h-8"
                  >${unsafeSVG(bannerSvg)}</span
                >
              </a>
            </li>
          </ul>
          ${this.renderAuth()}
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
