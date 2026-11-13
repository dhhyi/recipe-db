import { LitElement, html } from "lit";
import { customElement, property, state } from "lit/decorators.js";
import { unsafeSVG } from "lit/directives/unsafe-svg.js";
import bannerSvg from "../assets/banner.svg?raw";
import profileIconSvg from "../assets/Sample_User_Icon.svg?raw";

@customElement("header-component")
export class HeaderComponent extends LitElement {
  @property({ attribute: "auth-role" })
  authRole = "";

  @property({ attribute: "auth-email" })
  authEmail = "";

  @property({ type: Boolean, attribute: "auth-enabled" })
  authEnabled = false;

  @state()
  private scrollHidden = false;

  private directionalScrolling = false;
  private previousScrollY = 0;
  private scrollDistance = 0;
  private resizeObserver?: ResizeObserver;

  connectedCallback() {
    super.connectedCallback();
    void this.updateComplete.then(() => {
      if (!this.isConnected || this.resizeObserver) return;
      this.resizeObserver = new ResizeObserver(this.measureHeader);
      this.resizeObserver.observe(this.querySelector("header")!);
      window.addEventListener("scroll", this.onScroll, { passive: true });
      window.addEventListener("resize", this.measureHeader);
      window.addEventListener("orientationchange", this.measureHeader);
      window.visualViewport?.addEventListener("resize", this.measureHeader);
      this.measureHeader();
    });
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this.resizeObserver?.disconnect();
    this.resizeObserver = undefined;
    window.removeEventListener("scroll", this.onScroll);
    window.removeEventListener("resize", this.measureHeader);
    window.removeEventListener("orientationchange", this.measureHeader);
    window.visualViewport?.removeEventListener("resize", this.measureHeader);
  }

  private measureHeader = () => {
    const height = this.querySelector("header")!.getBoundingClientRect().height;
    const viewportHeight = window.visualViewport?.height ?? window.innerHeight;
    this.directionalScrolling =
      viewportHeight > 0 && height >= viewportHeight * 0.1;
    this.previousScrollY = this.currentScrollY();
    this.scrollDistance = 0;
    if (!this.directionalScrolling || this.previousScrollY === 0) {
      this.scrollHidden = false;
    }
  };

  private currentScrollY() {
    return Math.max(
      0,
      Math.min(
        window.scrollY,
        document.documentElement.scrollHeight - window.innerHeight,
      ),
    );
  }

  private revealForFocus() {
    this.scrollHidden = false;
    this.scrollDistance = 0;
    this.previousScrollY = this.currentScrollY();
  }

  private onScroll = () => {
    const scrollY = this.currentScrollY();
    const delta = scrollY - this.previousScrollY;
    this.previousScrollY = scrollY;
    if (
      !this.directionalScrolling ||
      scrollY === 0 ||
      this.contains(document.activeElement)
    ) {
      this.scrollHidden = false;
      this.scrollDistance = 0;
      return;
    }
    if (delta === 0) return;
    if (Math.sign(delta) !== Math.sign(this.scrollDistance)) {
      this.scrollDistance = 0;
    }
    this.scrollDistance += delta;
    if (Math.abs(this.scrollDistance) >= 8) {
      this.scrollHidden = this.scrollDistance > 0;
      this.scrollDistance = 0;
    }
  };

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
          <summary aria-label="Profil">
            <span class="profile-caption hidden sm:inline">Profil</span>
            <span
              class="profile-icon inline-flex h-[1em] align-middle sm:hidden *:block *:h-full *:w-auto"
              aria-hidden="true"
              >${unsafeSVG(profileIconSvg)}</span
            >
          </summary>
          <ul
            class="profile-menu w-max min-w-0 max-w-[calc(100vw-3rem)] text-right whitespace-normal"
            dir="rtl"
          >
            ${
              this.authEmail
                ? html`<li>
                    <small
                      class="profile-email block wrap-anywhere text-right select-text whitespace-normal"
                      dir="ltr"
                      >${this.authEmail}</small
                    >
                  </li>`
                : null
            }
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
        ?data-scroll-hidden=${this.scrollHidden}
        @focusin=${this.revealForFocus}
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
