import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

import "../design.css";

const meta = {
  title: "Blades/Link",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

export const Links: Story = {
  render: () => html`
    <main class="container">
      <p><a href="#">Primary link</a></p>
      <p><a href="#" class="secondary">Secondary link (footer only)</a></p>
    </main>
  `,
};
