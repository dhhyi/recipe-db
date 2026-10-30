import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";
import { expect, within } from "storybook/test";

import "../components/footer.ts";
import "../design.css";

const meta = {
  title: "Components/Footer",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

export const ProjectReadme: Story = {
  play: async ({ canvasElement }) => {
    const link = within(canvasElement).getByRole("link", {
      name: "GitHub",
    });
    expect(link).toHaveAttribute(
      "href",
      "https://github.com/dhhyi/recipe-db/blob/main/README.md",
    );
  },
  render: () => html`<footer-component></footer-component>`,
};
