import { LitElement, css, html } from "lit";
import { customElement } from "lit/decorators.js";

@customElement("recipe-tile-component")
export class RecipeTile extends LitElement {
  static styles = css`
    :host {
      aspect-ratio: 4 / 3;
      --recipe-tile-title-background: var(--pico-card-background-color);
      --recipe-tile-title-color: var(--pico-h2-color);
      display: block;
      max-width: 100%;
      overflow: hidden;
      position: relative;
      border-radius: 1rem;
    }

    .tile,
    .image,
    .title {
      inset: 0;
      position: absolute;
    }

    .image {
      z-index: 0;
    }

    ::slotted([slot="image"]) {
      display: block;
      height: 100%;
      object-fit: cover;
      width: 100%;
    }

    .rating {
      background: rgb(0 0 0 / 65%);
      border-radius: 4px;
      color: white;
      padding: 0.25rem;
      position: absolute;
      right: 0.5rem;
      top: 0.5rem;
      z-index: 1;
    }

    .rating[hidden] {
      display: none;
    }

    .title {
      align-items: end;
      background: linear-gradient(
        to top,
        var(--recipe-tile-title-background),
        transparent 55%
      );
      display: flex;
      padding: 0 0.75rem;
      z-index: 1;
    }

    ::slotted(h2[slot="title"]),
    ::slotted(h3[slot="title"]) {
      color: var(--recipe-tile-title-color);
      overflow: hidden;
      padding-block-end: 0.1em !important;
      text-overflow: ellipsis;
      text-shadow: 0 1px 2px var(--recipe-tile-title-background);
      text-wrap: nowrap !important;
      white-space: nowrap !important;
      width: 100%;
    }
  `;

  private handleRatingSlotChange(event: Event) {
    const slot = event.currentTarget as HTMLSlotElement;
    slot.parentElement?.toggleAttribute(
      "hidden",
      slot.assignedElements().length === 0,
    );
  }

  render() {
    return html`
      <div class="tile">
        <div class="image"><slot name="image"></slot></div>
        <div class="rating" hidden>
          <slot name="rating" @slotchange=${this.handleRatingSlotChange}></slot>
        </div>
        <div class="title"><slot name="title"></slot></div>
      </div>
    `;
  }
}
