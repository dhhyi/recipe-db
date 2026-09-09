import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";
import { fn } from "storybook/test";

import "../components/rating.ts";
import "../design.css";

const meta = {
  title: "Components/Rating",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

export const Feedback: Story = {
  args: {
    rating: 3.5,
    count: 10,
    onRated: fn(),
  },
  argTypes: {
    rating: { control: "number" },
    count: { control: "number" },
  },
  render: ({ rating, count, onRated }) => html`
    <rating-component
      hx-post="/rate"
      rating=${rating}
      count=${count}
      @rated=${(event: CustomEvent<number>) => onRated(event.detail)}
    ></rating-component>
  `,
};

export const Static: Story = {
  args: {
    rating: 3.5,
    count: 10,
  },
  argTypes: {
    rating: { control: "number" },
    count: { control: "number" },
  },
  render: ({ rating, count }) => html`
    <rating-component rating=${rating} count=${count}></rating-component>
  `,
};

export const All: Story = {
  args: {},
  render: () => html`
    ${[0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5].map(
      (rating) => html`<rating-component rating=${rating}></rating-component>`,
    )}
  `,
};
