import { LitElement, html, svg } from "lit";
import { customElement, property } from "lit/decorators.js";

@customElement("rating-component")
export class RatingComponent extends LitElement {
  protected createRenderRoot() {
    return this;
  }

  private star = (num: number, type: "full" | "half" | "empty") =>
    svg`<svg @click=${() => this.handleClick(num + 1)} viewBox="-1 -1 25 25" width="27" height="22">${
      type === "half"
        ? svg`<defs>
            <linearGradient id="half">
              <stop offset="50%" stop-color="currentColor" stop-opacity="1"/>
              <stop offset="50%" stop-color="currentColor" stop-opacity="0"/>
            </linearGradient>
          </defs>`
        : ""
    }<path d="M12 .587l3.668 7.431 8.2 1.192-5.934 5.782 1.4 8.168L12 18.896l-7.334 3.864 1.4-8.168-5.934-5.782 8.2-1.192z" stroke="currentColor" stroke-width="2" fill="${type === "full" ? "currentColor" : type === "half" ? "url(#half)" : "none"}"/>
      </svg>`;

  @property({ type: Number })
  rating = 0;

  @property({ type: Number })
  count = undefined;

  private handleClick = (num: number) => {
    this.dispatchEvent(new CustomEvent<number>("rated", { detail: num }));
  };

  render() {
    return html`<span class="flex items-center"
      >${Array.from({ length: 5 }, (_, i) => {
        const value = i + 1;
        return value <= this.rating
          ? this.star(i, "full")
          : value - 0.5 <= this.rating
            ? this.star(i, "half")
            : this.star(i, "empty");
      })}${this.count !== undefined ? html`&nbsp;(${this.count})` : ""}</span
    >`;
  }
}
