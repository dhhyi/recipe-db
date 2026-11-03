import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

import "../design.css";

const meta = {
  title: "Blades/Button",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

export const Buttons: Story = {
  render: () => html`
    <main class="container">
      <button type="button">Primary</button>
      <button type="button" class="outline">Secondary</button>
    </main>
  `,
};
