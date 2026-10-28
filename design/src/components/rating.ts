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
    return svg`<svg @click=${() => this.handleClick(num + 1)} viewBox="-1 -1 25 25" width="27" height="22">
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

  private handleClick = (num: number) => {
    if (this.hasAttribute("hx-post") && num !== this.myRating) {
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
