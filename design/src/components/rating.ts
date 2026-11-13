import { LitElement, html, svg } from "lit";
import { customElement, property, state } from "lit/decorators.js";

@customElement("rating-component")
export class RatingComponent extends LitElement {
  protected createRenderRoot() {
    // drop stale render output restored e.g. from htmx history cache
    this.replaceChildren();
    return this;
  }

  private star = (num: number) => {
    const fill = Math.max(0, Math.min(1, this.rating - num)) * 100;
    const ownFill = Math.max(0, Math.min(1, (this.myRating ?? 0) - num)) * 100;
    const path =
      "M12 .587l3.668 7.431 8.2 1.192-5.934 5.782 1.4 8.168L12 18.896l-7.334 3.864 1.4-8.168-5.934-5.782 8.2-1.192z";
    return svg`<svg @click=${(event: MouseEvent) => this.handleClick(num + 1, event)} viewBox="-1 -1 25 25" width="27" height="22">
        <path d=${path} fill="currentColor" style="clip-path: inset(0 ${100 - fill}% 0 0)"/>
        ${
          this.myRating !== undefined && !this.editing
            ? svg`<path class="own-rating" d=${path} fill="#ffec17" opacity="0.5" style="clip-path: inset(0 ${100 - ownFill}% 0 0)"/>`
            : null
        }
        <path class="rating-outline" d=${path} stroke="currentColor" stroke-width="2" fill="none"/>
    </svg>`;
  };

  @property({ type: Number })
  rating = 0;

  @property({ type: Number, attribute: "my-rating" })
  myRating: number | undefined = undefined;

  @state()
  private editing = false;

  @property({ type: Number })
  count = undefined;

  protected firstUpdated() {
    // A fast HTMX response replaces the clicked star before its pulse finishes.
    if (
      this.hasAttribute("hx-post") &&
      this.closest("[data-rating-saved]") &&
      this.myRating !== undefined
    ) {
      const star = this.querySelectorAll("svg")[this.myRating - 1];
      if (star) this.pulseStar(star);
    }
  }

  private pulseStar(star: SVGElement) {
    if (!matchMedia("(prefers-reduced-motion: reduce)").matches) {
      star.animate(
        [
          { transform: "scale(1) rotate(0deg)" },
          { transform: "scale(1.4) rotate(-20deg)" },
          { transform: "scale(1.3) rotate(18deg)" },
          { transform: "scale(1.2) rotate(-12deg)" },
          { transform: "scale(1.1) rotate(7deg)" },
          { transform: "scale(1) rotate(0deg)" },
        ],
        { duration: 550, easing: "ease-out" },
      );
    }
  }

  private handleClick = (num: number, event: MouseEvent) => {
    if (this.hasAttribute("hx-post") && num !== this.myRating) {
      if (event.currentTarget instanceof SVGElement) {
        this.pulseStar(event.currentTarget);
      }
      this.dispatchEvent(new CustomEvent<number>("rated", { detail: num }));
    }
  };

  render() {
    return html`<span
      class="flex items-center"
      @mouseenter=${() => {
        this.editing = this.hasAttribute("hx-post");
      }}
      @mouseleave=${() => {
        this.editing = false;
      }}
      >${Array.from({ length: 5 }, (_, i) => this.star(i))}${this.count !== undefined ? html`&nbsp;(${this.count})` : ""}</span
    >`;
  }
}
