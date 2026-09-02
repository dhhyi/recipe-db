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
      <article aria-label="Heading scale">
        <h1>Heading 1</h1>
        <h2>Heading 2</h2>
        <h3>Heading 3</h3>
        <h4>Heading 4</h4>
        <h5>Heading 5</h5>
        <h6>Heading 6</h6>
        <p>Paragraph text</p>
      </article>
    </main>
  `,
};

export const Group: Story = {
  render: () => html`
    <main class="container">
      <article aria-label="Heading group">
        <hgroup>
          <h2>Weeknight recipes</h2>
          <p>Fast dinners sorted by prep time and pantry fit.</p>
        </hgroup>
      </article>
    </main>
  `,
};

export const WithAnchor: Story = {
  render: () => html`
    <main class="container">
      <article aria-label="Heading anchor">
        <h2 id="popular-recipes">
          Popular recipes
          <a href="#popular-recipes" aria-hidden="true">#</a>
        </h2>
        <p>
          Heading anchors appear on hover while keeping the heading semantic.
        </p>
      </article>
    </main>
  `,
};
