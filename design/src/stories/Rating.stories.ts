import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html, nothing } from "lit";
import { expect, fireEvent, fn, waitFor } from "storybook/test";

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
    fireEvent.mouseEnter(stars);
    await waitFor(() => {
      expect(stars.querySelectorAll(".own-rating")).toHaveLength(0);
    });
    fireEvent.mouseLeave(stars);
    await waitFor(() => {
      expect(stars.querySelectorAll(".own-rating")).toHaveLength(
        expectedOverlays,
      );
    });
    args.onRated.mockClear();
    if (args.myRating !== undefined) {
      fireEvent.click(stars.querySelectorAll("svg")[args.myRating - 1]);
      expect(args.onRated).not.toHaveBeenCalled();
    }
    const changedRating = args.myRating === 1 ? 2 : 1;
    fireEvent.click(stars.querySelectorAll("svg")[changedRating - 1]);
    expect(args.onRated).toHaveBeenCalledTimes(1);
    expect(args.onRated).toHaveBeenCalledWith(changedRating);
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
