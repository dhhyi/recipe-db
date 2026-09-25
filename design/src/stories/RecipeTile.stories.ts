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
