import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

import "../design.css";

const meta = {
  title: "Blades/Loading",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

export const Inline: Story = {
  render: () => html`
    <main class="container">
      <span aria-busy="true">Generating shopping list...</span>
    </main>
  `,
};

export const Buttons: Story = {
  render: () => html`
    <main class="container">
      <button aria-busy="true" type="button">Please wait</button>
      <button aria-busy="true" type="button" class="secondary">
        Please wait
      </button>
      <button aria-busy="true" type="button" class="outline contrast">
        Please wait
      </button>
    </main>
  `,
};
