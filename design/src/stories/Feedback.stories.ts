import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

import "../design.css";

const meta = {
  title: "Blades/Feedback",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

export const Success: Story = {
  render: () => html`
    <main class="container">
      <p class="feedback success" role="alert">Bild hochgeladen</p>
    </main>
  `,
};

export const Error: Story = {
  render: () => html`
    <main class="container">
      <p class="feedback error" role="alert">Fehler beim Hochladen</p>
    </main>
  `,
};
