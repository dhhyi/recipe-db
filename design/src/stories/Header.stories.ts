import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";
import { LoremIpsum } from "lorem-ipsum";

import "../components/header.ts";
import "../design.css";

const meta = {
  title: "Components/Header",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

const lorem = new LoremIpsum();

export const Sticky: Story = {
  render: () => html`
    <header-component></header-component>
    <main class="p-2">
      ${lorem
        .generateParagraphs(20)
        .split("\n")
        .map((text) => html`<p>${text}</p>`)}
    </main>
  `,
};
