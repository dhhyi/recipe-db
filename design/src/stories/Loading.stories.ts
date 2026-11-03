import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

import "../design.css";

const meta = {
  title: "Blades/Loading",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

export const Placeholder: Story = {
  render: () => html`
    <main class="container">
      <div aria-busy="true" aria-label="Rezept wird geladen"></div>
    </main>
  `,
};

export const PlaceholderError: Story = {
  render: () => html`
    <main class="container">
      <p class="feedback error" role="alert">
        Ähnliche Rezepte konnten nicht geladen werden.
      </p>
      <button type="button" class="outline">Erneut versuchen</button>
    </main>
  `,
};

export const Buttons: Story = {
  render: () => html`
    <main class="container">
      <button aria-busy="true" type="button" disabled>Speichern</button>
      <button aria-busy="true" type="button" class="outline" disabled>
        Erneut versuchen
      </button>
    </main>
  `,
};
