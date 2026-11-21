import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html, nothing } from "lit";
import { expect, fn, waitFor } from "storybook/test";

import "../components/rating.ts";
import "../design.css";

const meta = {
  title: "Components/Rating",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

export const Feedback: Story = {
  play: async ({ canvasElement, args }) => {
    const rating = canvasElement.querySelector("rating-component");
    expect(rating).toHaveAttribute("rating", String(args.rating));
    expect(rating).toHaveAttribute("count", String(args.count));
    await waitFor(() => {
      expect(
        canvasElement.querySelectorAll("rating-component svg"),
      ).toHaveLength(5);
    });
    const stars = canvasElement.querySelector("rating-component > span")!;
    const expectedOverlays = args.myRating === undefined ? 0 : 5;
    await waitFor(() => {
      expect(stars.querySelectorAll(".own-rating")).toHaveLength(
        expectedOverlays,
      );
    });
  },
  args: {
    rating: 3.5,
    count: 10,
    myRating: 4,
    onRated: fn(),
  },
  argTypes: {
    rating: { control: "number" },
    count: { control: "number" },
    myRating: { control: "number" },
  },
  render: ({ rating, count, myRating, onRated }) => html`
    <rating-component
      hx-post="/rate"
      rating=${rating}
      count=${count}
      my-rating=${myRating ?? nothing}
      @rated=${(event: CustomEvent<number>) => onRated(event.detail)}
    ></rating-component>
  `,
};

export const NoOwnVote: Story = {
  ...Feedback,
  args: { ...Feedback.args, myRating: undefined },
};

export const Static: Story = {
  play: async ({ canvasElement }) => {
    await waitFor(() => {
      expect(
        canvasElement.querySelectorAll("rating-component svg"),
      ).toHaveLength(5);
    });
    const rating = canvasElement.querySelector("rating-component");
    expect(rating).not.toHaveAttribute("hx-post");
    expect(rating?.querySelectorAll(".own-rating")).toHaveLength(0);
  },
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
