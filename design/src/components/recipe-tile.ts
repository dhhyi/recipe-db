import { LitElement, css, html } from "lit";
import { customElement } from "lit/decorators.js";

const imageNotAvailableUrl = new URL(
  "../assets/image-not-available.svg?no-inline",
  import.meta.url,
).href;

@customElement("recipe-tile-component")
export class RecipeTile extends LitElement {
  private image?: HTMLImageElement;

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

    :host([aria-busy="true"])::before {
      left: 50%;
      position: absolute;
      top: 50%;
      transform: translate(-50%, -50%);
      z-index: 2;
    }

    .tile,
    .image,
    .title {
      inset: 0;
      position: absolute;
    }

    .image {
      align-items: center;
      background: color-mix(in srgb, currentColor 8%, transparent);
      color: color-mix(in srgb, currentColor 62%, transparent);
      display: flex;
      justify-content: center;
      z-index: 0;
    }

    .fallback-image {
      height: 46%;
      max-height: 8rem;
      max-width: 8rem;
      width: 46%;
    }

    .fallback-image[hidden] {
      display: none;
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

  private handleImageSlotChange(event: Event) {
    const slot = event.currentTarget as HTMLSlotElement;
    this.updateImageFallback(slot);
  }

  private handleImageLoad = (event: Event) => {
    this.markImageLoaded(event.currentTarget as HTMLImageElement);
  };

  private handleImageError = (event: Event) => {
    const image = event.currentTarget as HTMLImageElement;

    if (!this.hasImageSource(image)) {
      this.markImageLoading(image);
      return;
    }

    this.markImageFailed(image);
  };

  private markImageLoading(image: HTMLImageElement) {
    image.hidden = true;
    this.setAttribute("aria-busy", "true");
    this.toggleImageFallback(false);
  }

  private markImageLoaded(image: HTMLImageElement) {
    image.hidden = false;
    this.removeAttribute("aria-busy");
    this.toggleImageFallback(false);
  }

  private markImageFailed(image: HTMLImageElement) {
    image.hidden = true;
    this.removeAttribute("aria-busy");
    this.toggleImageFallback(true);
  }

  private hasImageSource(image: HTMLImageElement) {
    return Boolean(image.getAttribute("src"));
  }

  private toggleImageFallback(visible: boolean) {
    this.shadowRoot
      ?.querySelector(".fallback-image")
      ?.toggleAttribute("hidden", !visible);
  }

  private updateImageFallback(slot: HTMLSlotElement) {
    const image = slot
      .assignedElements()
      .find(
        (element): element is HTMLImageElement =>
          element instanceof HTMLImageElement,
      );

    if (this.image !== image) {
      this.image?.removeEventListener("load", this.handleImageLoad);
      this.image?.removeEventListener("error", this.handleImageError);
      this.image = image;
      image?.addEventListener("load", this.handleImageLoad);
      image?.addEventListener("error", this.handleImageError);
    }

    if (!image) {
      this.removeAttribute("aria-busy");
      this.toggleImageFallback(true);
      return;
    }

    if (image.complete && this.hasImageSource(image)) {
      if (image.naturalWidth > 0) {
        this.markImageLoaded(image);
      } else {
        this.markImageFailed(image);
      }
      return;
    }

    this.markImageLoading(image);
  }

  protected firstUpdated() {
    const imageSlot =
      this.shadowRoot?.querySelector<HTMLSlotElement>('slot[name="image"]');
    if (imageSlot) {
      this.updateImageFallback(imageSlot);
    }
  }

  render() {
    return html`
      <div class="tile">
        <div class="image">
          <img
            alt="Image not available"
            class="fallback-image"
            hidden
            src=${imageNotAvailableUrl}
          />
          <slot name="image" @slotchange=${this.handleImageSlotChange}></slot>
        </div>
        <div class="rating" hidden>
          <slot name="rating" @slotchange=${this.handleRatingSlotChange}></slot>
        </div>
        <div class="title"><slot name="title"></slot></div>
      </div>
    `;
  }
}
