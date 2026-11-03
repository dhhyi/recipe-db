import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

import "../design.css";

const meta = {
  title: "Blades/Headings",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

export const Scale: Story = {
  render: () => html`
    <main class="container">
      <h1>Heading 1</h1>
      <h2>Heading 2</h2>
      <h3>Heading 3</h3>
      <p>Paragraph text</p>
    </main>
  `,
};

export const Group: Story = {
  render: () => html`
    <main class="container">
      <hgroup>
        <h2>Weeknight recipes</h2>
        <p>Fast dinners sorted by prep time and pantry fit.</p>
      </hgroup>
    </main>
  `,
};
