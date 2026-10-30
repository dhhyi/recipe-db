import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";
import { until } from "lit/directives/until.js";

import carbonaraThumb from "../assets/carbonara-thumb.png";
import "../components/rating.ts";
import "../components/recipe-tile.ts";
import "../design.css";

const meta = {
  title: "Components/Recipe Tile",
  tags: ["autodocs"],
  args: {
    rating: 4.5,
    title: "Spaghetti Carbonara",
  },
  argTypes: {
    rating: { control: "number" },
    title: { control: "text" },
  },
} satisfies Meta;

export default meta;
type Story = StoryObj;

const tags = (entries: [string, string][]) =>
  entries.map(
    ([category, name]) =>
      html`<span
        slot="tags"
        class="recipe-tag recipe-tag--${category}"
        data-recipe-tag
        aria-label="${category}: ${name}"
        >${name}</span
      >`,
  );

const overflow = html`<span
  slot="tags"
  class="recipe-tag"
  data-tag-overflow
  hidden
  >+1</span
>`;

export const Full: Story = {
  render: ({ rating, title }) => html`
    <a>
      <recipe-tile-component>
        <img slot="image" src=${carbonaraThumb} alt="Spaghetti carbonara" />
        <rating-component slot="rating" rating=${rating}></rating-component>
        <h2 slot="title">${title}</h2>
      </recipe-tile-component>
    </a>
  `,
};

export const PopulatedTags: Story = {
  render: ({ title }) => html`
    <a>
      <recipe-tile-component>
        <img slot="image" src=${carbonaraThumb} alt="Spaghetti carbonara" />
        <h2 slot="title">${title}</h2>
        ${tags([
          ["cuisine", "Italienisch"],
          ["dietary-style", "Vegetarisch"],
          ["course", "Hauptgericht"],
        ])}
        ${overflow}
      </recipe-tile-component>
    </a>
  `,
};

export const CappedTags: Story = {
  render: ({ title }) => html`
    <a>
      <recipe-tile-component>
        <img slot="image" src=${carbonaraThumb} alt="Spaghetti carbonara" />
        <h2 slot="title">${title}</h2>
        ${tags([
          ["cuisine", "Italienisch"],
          ["dietary-style", "Vegetarisch"],
          ["course", "Hauptgericht"],
          ["course", "Abendessen"],
          ["course", "Pasta"],
        ])}
        ${overflow}
      </recipe-tile-component>
    </a>
  `,
};

export const NarrowTags: Story = {
  render: ({ title }) => html`
    <div style="width: 12rem">
      <a>
        <recipe-tile-component>
          <img slot="image" src=${carbonaraThumb} alt="Spaghetti carbonara" />
          <h2 slot="title">${title}</h2>
          ${tags([
            ["cuisine", "Italienisch"],
            ["dietary-style", "Vegetarisch"],
            ["course", "Hauptgericht"],
          ])}
          ${overflow}
        </recipe-tile-component>
      </a>
    </div>
  `,
};

export const LongNameTags: Story = {
  render: ({ title }) => html`
    <a>
      <recipe-tile-component>
        <img slot="image" src=${carbonaraThumb} alt="Spaghetti carbonara" />
        <h2 slot="title">${title}</h2>
        ${tags([
          ["cuisine", "Eine außergewöhnlich lange Küchenbezeichnung"],
          ["dietary-style", "Vegetarisch"],
          ["course", "Hauptgericht"],
          ["course", "Abendessen"],
        ])}
        ${overflow}
      </recipe-tile-component>
    </a>
  `,
};

export const DarkThemeTags: Story = {
  render: ({ title }) => html`
    <div
      data-theme="dark"
      style="background: #1f2937; color: white; padding: 1rem"
    >
      <a>
        <recipe-tile-component>
          <img slot="image" src=${carbonaraThumb} alt="Spaghetti carbonara" />
          <h2 slot="title">${title}</h2>
          ${tags([
            ["cuisine", "Italienisch"],
            ["dietary-style", "Vegetarisch"],
            ["course", "Hauptgericht"],
          ])}
          ${overflow}
        </recipe-tile-component>
      </a>
    </div>
  `,
};

export const Light: Story = {
  render: ({ title }) => html`
    <a>
      <recipe-tile-component>
        <img slot="image" src=${carbonaraThumb} alt="Spaghetti carbonara" />
        <h2 slot="title">${title}</h2>
      </recipe-tile-component>
    </a>
  `,
};

export const Empty: Story = {
  render: ({ title }) => html`
    <a>
      <recipe-tile-component>
        <h2 slot="title">${title}</h2>
      </recipe-tile-component>
    </a>
  `,
};

export const Loading: Story = {
  render: ({ title }) => {
    const source = new Promise<string>((resolve) => {
      setTimeout(() => resolve(carbonaraThumb), 2000);
    });

    return html`
      <a>
        <recipe-tile-component>
          <img
            slot="image"
            src=${until(source, "")}
            alt="Spaghetti carbonara"
          />
          <h2 slot="title">${title}</h2>
        </recipe-tile-component>
      </a>
    `;
  },
};

export const Error: Story = {
  render: ({ title }) => html`
    <a>
      <recipe-tile-component>
        <img
          slot="image"
          src="/missing-recipe-thumbnail.png"
          alt="Spaghetti carbonara"
        />
        <h2 slot="title">${title}</h2>
      </recipe-tile-component>
    </a>
  `,
};
