import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

import "../design.css";

const meta = {
  title: "Components/Recipe Tags",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

const pills = () => html`
  <div class="flex flex-wrap gap-1">
    <span class="recipe-tag recipe-tag--cuisine" aria-label="Cuisine: Deutsch"
      >Deutsch</span
    >
    <span
      class="recipe-tag recipe-tag--dietary-style"
      aria-label="Dietary style: Vegetarisch"
      >Vegetarisch</span
    >
    <span
      class="recipe-tag recipe-tag--course"
      aria-label="Course: Hauptgericht"
      >Hauptgericht</span
    >
  </div>
`;

const legend = () => html`
  <ul class="markerless flex flex-wrap gap-2" aria-label="Tag-Kategorien">
    <li class="flex items-center gap-1">
      <span class="recipe-tag recipe-tag--cuisine" aria-hidden="true"></span>
      <span>Cuisine</span>
    </li>
    <li class="flex items-center gap-1">
      <span
        class="recipe-tag recipe-tag--dietary-style"
        aria-hidden="true"
      ></span>
      <span>Dietary style</span>
    </li>
    <li class="flex items-center gap-1">
      <span class="recipe-tag recipe-tag--course" aria-hidden="true"></span>
      <span>Course</span>
    </li>
  </ul>
`;

export const Populated: Story = {
  render: () => html`
    <section class="recipe-tags-detail flex flex-col gap-2">
      ${pills()} ${legend()}
    </section>
  `,
};

export const Empty: Story = {
  render: () => html`<section class="recipe-tags-detail"></section>`,
};

export const LongNames: Story = {
  render: () => html`
    <section class="recipe-tags-detail flex flex-col gap-2">
      <div class="flex flex-wrap gap-1">
        <span
          class="recipe-tag recipe-tag--cuisine"
          aria-label="Cuisine: Eine besonders lange Küchenbezeichnung"
          >Eine besonders lange Küchenbezeichnung für ein traditionelles
          Gericht</span
        >
        <span
          class="recipe-tag recipe-tag--course"
          aria-label="Course: Hauptgericht"
          >Hauptgericht</span
        >
      </div>
      ${legend()}
    </section>
  `,
};

export const DarkTheme: Story = {
  render: () => html`
    <div
      data-theme="dark"
      style="background: #1f2937; color: white; padding: 1rem"
    >
      <section class="recipe-tags-detail flex flex-col gap-2">
        ${pills()} ${legend()}
      </section>
    </div>
  `,
};
