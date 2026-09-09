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
    <main style="padding: 0.5rem 0;">
      <h1>${lorem.generateWords(3)}</h1>
      ${lorem
        .generateParagraphs(5)
        .split("\n")
        .map((text) => html`<p class="text-justify">${text}</p>`)}
    </main>
  `,
};
