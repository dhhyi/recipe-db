import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

import "../design.css";

const meta = {
  title: "Blades/Lists",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

export const Basic: Story = {
  render: () => html`
    <main class="container">
      <article aria-label="Basic lists">
        <h3>Ingredients</h3>
        <ul>
          <li>Rigatoni</li>
          <li>Roasted squash</li>
          <li>Sage butter</li>
        </ul>
        <h3>Method</h3>
        <ol>
          <li>Boil the pasta.</li>
          <li>Brown the butter with sage.</li>
          <li>Toss everything together.</li>
        </ol>
      </article>
    </main>
  `,
};

export const CustomMarkers: Story = {
  render: () => html`
    <main class="container">
      <article aria-label="Custom list markers">
        <ul style="--list-marker:'> '">
          <li>Prep the ingredients</li>
          <li>Cook the base</li>
          <li style="--list-marker:'* '">Finish with herbs</li>
        </ul>
      </article>
    </main>
  `,
};

export const Markerless: Story = {
  render: () => html`
    <main class="container">
      <article aria-label="Markerless list">
        <ul class="markerless">
          <li>1. Draft recipe</li>
          <li>2. Test quantities</li>
          <li>3. Publish notes</li>
        </ul>
      </article>
    </main>
  `,
};

export const UnlistGrid: Story = {
  render: () => html`
    <main class="container">
      <ul class="unlist grid" style="margin: 0">
        <li><article>Breakfast</article></li>
        <li><article>Dinner</article></li>
        <li><article>Dessert</article></li>
      </ul>
    </main>
  `,
};
