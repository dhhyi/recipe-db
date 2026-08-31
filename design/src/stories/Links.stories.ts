import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

import "../design.css";

const meta = {
  title: "Blades/Links",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

export const Variants: Story = {
  render: () => html`
    <main class="container">
      <article aria-label="Link variants">
        <p><a href="#">Primary link</a></p>
        <p><a href="#" class="secondary">Secondary link</a></p>
        <p><a href="#" class="contrast">Contrast link</a></p>
      </article>
    </main>
  `,
};

export const Current: Story = {
  render: () => html`
    <main class="container">
      <article aria-label="Current link state">
        <p><a href="#">All recipes</a></p>
        <p><a href="#" aria-current="page">Favorites</a></p>
        <p><a href="#">Shopping list</a></p>
      </article>
    </main>
  `,
};

export const AsButtons: Story = {
  render: () => html`
    <main class="container">
      <article aria-label="Links rendered as buttons">
        <a href="#" role="button">Primary action</a>
        <a href="#" role="button" class="secondary">Secondary action</a>
        <a href="#" role="button" class="outline contrast">Quiet action</a>
      </article>
    </main>
  `,
};
