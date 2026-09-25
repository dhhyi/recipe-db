import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

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
