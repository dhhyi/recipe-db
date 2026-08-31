import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

import "../design.css";

const meta = {
  title: "Blades/Loading",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

export const Block: Story = {
  render: () => html`
    <main class="container">
      <article aria-label="Loading card" aria-busy="true"></article>
    </main>
  `,
};

export const Inline: Story = {
  render: () => html`
    <main class="container">
      <article aria-label="Inline loading">
        <span aria-busy="true">Generating shopping list...</span>
      </article>
    </main>
  `,
};

export const Buttons: Story = {
  render: () => html`
    <main class="container">
      <article aria-label="Loading buttons">
        <button aria-busy="true" type="button">Please wait</button>
        <button aria-busy="true" type="button" class="secondary">
          Please wait
        </button>
        <button aria-busy="true" type="button" class="outline contrast">
          Please wait
        </button>
      </article>
    </main>
  `,
};
