import Swiper from "swiper";
import { A11y, Navigation, Pagination } from "swiper/modules";
import "swiper/css";
import "swiper/css/navigation";
import "swiper/css/pagination";
import imageNotAvailableUrl from "../assets/image-not-available.svg?no-inline";

const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

export class RecipeImageCarousel extends HTMLElement {
  private swiper?: Swiper;
  private images: HTMLImageElement[] = [];
  private lastFocusedControl?: HTMLButtonElement;

  connectedCallback() {
    if (this.swiper) return;
    this.images = Array.from(this.querySelectorAll("img"));
    this.images.forEach((image) => {
      image.addEventListener("error", this.handleImageError);
      if (image.complete && image.naturalWidth === 0) {
        this.useFallback(image);
      }
    });

    const container = this.querySelector<HTMLElement>(".swiper");
    const previous = this.querySelector<HTMLElement>("[data-carousel-prev]");
    const next = this.querySelector<HTMLElement>("[data-carousel-next]");
    const pagination = this.querySelector<HTMLElement>(
      "[data-carousel-pagination]",
    );
    if (
      this.images.length < 2 ||
      !container ||
      !previous ||
      !next ||
      !pagination
    ) {
      return;
    }

    this.dataset.enhanced = "true";
    try {
      this.swiper = new Swiper(container, {
        modules: [Navigation, Pagination, A11y],
        loop: false,
        rewind: false,
        navigation: {
          prevEl: previous,
          nextEl: next,
        },
        pagination: {
          el: pagination,
          clickable: true,
        },
        a11y: {
          containerRole: "region",
          containerMessage: "Rezeptbilder",
          containerRoleDescriptionMessage: "Karussell",
          prevSlideMessage: "Vorheriges Bild",
          nextSlideMessage: "Nächstes Bild",
          firstSlideMessage: "Erstes Bild",
          lastSlideMessage: "Letztes Bild",
          paginationBulletMessage: "Zu Bild {{index}}",
          slideLabelMessage: "Bild {{index}} von {{slidesLength}}",
        },
        ...(reducedMotion.matches ? { speed: 0 } : {}),
      });
    } catch (error) {
      delete this.dataset.enhanced;
      console.error("Could not initialize recipe image carousel", error);
      return;
    }

    this.querySelectorAll<HTMLElement>(
      "[data-carousel-prev], [data-carousel-next], [data-carousel-pagination]",
    ).forEach((control) => control.removeAttribute("hidden"));
    this.swiper.on("slideChange", this.handleSlideChange);
    this.addEventListener("keydown", this.handleKeyDown);
    this.addEventListener("focusin", this.handleFocusIn);
    reducedMotion.addEventListener("change", this.handleMotionChange);
    this.swiper.update();
  }

  disconnectedCallback() {
    this.removeEventListener("keydown", this.handleKeyDown);
    this.removeEventListener("focusin", this.handleFocusIn);
    reducedMotion.removeEventListener("change", this.handleMotionChange);
    this.images.forEach((image) => {
      image.removeEventListener("error", this.handleImageError);
    });
    this.images = [];
    this.swiper?.destroy(true, true);
    this.swiper = undefined;
    this.lastFocusedControl = undefined;
    delete this.dataset.enhanced;
  }

  private handleImageError = (event: Event) => {
    const image = event.currentTarget;
    if (image instanceof HTMLImageElement) this.useFallback(image);
  };

  private useFallback(image: HTMLImageElement) {
    if (image.dataset.fallback === "true") return;
    image.dataset.fallback = "true";
    image.src = imageNotAvailableUrl;
  }

  private handleKeyDown = (event: KeyboardEvent) => {
    if (
      !this.swiper ||
      event.altKey ||
      event.ctrlKey ||
      event.metaKey ||
      event.shiftKey ||
      (event.target instanceof HTMLElement &&
        (event.target.isContentEditable ||
          event.target.matches("input, textarea, select")))
    ) {
      return;
    }
    if (event.key === "ArrowLeft") {
      event.preventDefault();
      this.swiper.slidePrev();
    } else if (event.key === "ArrowRight") {
      event.preventDefault();
      this.swiper.slideNext();
    }
  };

  private handleSlideChange = () => {
    const focusedControl = this.lastFocusedControl;
    requestAnimationFrame(() => {
      const active = document.activeElement;
      const disabledControl =
        active instanceof HTMLButtonElement && active.disabled
          ? active
          : active === document.body && focusedControl?.disabled
            ? focusedControl
            : undefined;
      if (!disabledControl) return;
      const previous = this.querySelector<HTMLButtonElement>(
        "[data-carousel-prev]",
      );
      const next = this.querySelector<HTMLButtonElement>(
        "[data-carousel-next]",
      );
      if (disabledControl === previous) next?.focus();
      else if (disabledControl === next) previous?.focus();
    });
  };

  private handleFocusIn = (event: FocusEvent) => {
    this.lastFocusedControl =
      event.target instanceof HTMLButtonElement &&
      event.target.matches("[data-carousel-prev], [data-carousel-next]")
        ? event.target
        : undefined;
  };

  private handleMotionChange = (event: MediaQueryListEvent) => {
    if (this.swiper) this.swiper.params.speed = event.matches ? 0 : 300;
  };
}

if (!customElements.get("recipe-image-carousel")) {
  customElements.define("recipe-image-carousel", RecipeImageCarousel);
}
