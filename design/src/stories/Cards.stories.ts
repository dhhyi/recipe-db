import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

import "../design.css";

const meta = {
  title: "Blades/Cards",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

export const Basic: Story = {
  render: () => html`
    <main class="container">
      <article aria-label="Basic card">I'm a card.</article>
    </main>
  `,
};

export const Sectioned: Story = {
  render: () => html`
    <main class="container">
      <article aria-label="Card with sections">
        <header>Recipe draft</header>
        <p>
          Pasta with roasted squash, sage, and toasted breadcrumbs. Ready for
          review before it goes into the weeknight collection.
        </p>
        <footer>
          <a href="#">Open recipe</a>
        </footer>
      </article>
    </main>
  `,
};

export const CardGrid: Story = {
  render: () => html`
    <main class="container">
      <section class="grid" aria-label="Recipe cards">
        <article>
          <header>Breakfast</header>
          <p>Oats, berries, toasted seeds, and yogurt.</p>
          <footer><a href="#" class="secondary">View meals</a></footer>
        </article>
        <article>
          <header>Dinner</header>
          <p>Beans, herbs, greens, and a fast pan sauce.</p>
          <footer><a href="#" class="secondary">View meals</a></footer>
        </article>
      </section>
    </main>
  `,
};
