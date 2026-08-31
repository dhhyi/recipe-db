import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

import "../design.css";

interface ButtonProps {
  class?: string;
  label: string;
}

const Button = ({ class: classes, label }: ButtonProps) => {
  return html` <button type="button" class=${classes}>${label}</button> `;
};

const meta = {
  title: "Blades/Button",
  tags: ["autodocs"],
  render: (args) => Button(args),
  argTypes: {
    class: {
      control: { type: "select" },
      options: [
        undefined,
        "secondary",
        "contrast",
        "outline",
        "outline secondary",
        "outline contrast",
      ],
    },
  },
} satisfies Meta<ButtonProps>;

export default meta;
type Story = StoryObj<ButtonProps>;

export const Primary: Story = {
  args: {
    label: "Button",
  },
};

export const Secondary: Story = {
  args: {
    label: "Button",
    class: "secondary",
  },
};

export const Contrast: Story = {
  args: {
    class: "contrast",
    label: "Button",
  },
};

export const Outline: Story = {
  args: {
    class: "outline",
    label: "Button",
  },
};

export const OutlineSecondary: Story = {
  args: {
    class: "outline secondary",
    label: "Button",
  },
};

export const OutlineContrast: Story = {
  args: {
    class: "outline contrast",
    label: "Button",
  },
};
