import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";
import { LoremIpsum } from "lorem-ipsum";
import { expect, waitFor, within } from "storybook/test";

import "../components/header.ts";
import "../design.css";

const meta = {
  title: "Components/Header",
  tags: ["autodocs"],
  args: {
    authRole: "",
    authUnavailable: false,
  },
  argTypes: {
    authRole: {
      control: "select",
      options: ["", "anonymous", "member", "owner"],
    },
    authUnavailable: { control: "boolean" },
  },
} satisfies Meta;

export default meta;
type Story = StoryObj;

const lorem = new LoremIpsum();

export const Sticky: Story = {
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement);
    await waitFor(() => {
      const links = canvas
        .queryAllByRole("link")
        .filter((link) => link.getAttribute("href")?.startsWith("/oauth2/"));
      expect(links).toHaveLength(
        args.authRole && !args.authUnavailable ? 1 : 0,
      );
      if (args.authUnavailable) {
        expect(canvas.getByRole("status")).toHaveTextContent(
          "Anmeldung derzeit nicht verfügbar.",
        );
      }
      if (links.length) {
        const login = args.authRole === "anonymous";
        expect(links[0]).toHaveTextContent(login ? "Anmelden" : "Abmelden");
        if (!login) {
          expect(links[0]).toHaveAttribute("data-tooltip", args.authRole);
        }
      }
    });
  },
  render: ({ authRole, authUnavailable }) => html`
    <header-component
      auth-role=${authRole}
      ?auth-unavailable=${authUnavailable}
    ></header-component>
    <main style="padding: 0.5rem 0;">
      <h1>${lorem.generateWords(3)}</h1>
      ${lorem
        .generateParagraphs(5)
        .split("\n")
        .map((text) => html`<p class="text-justify">${text}</p>`)}
    </main>
  `,
};

export const Login: Story = {
  ...Sticky,
  args: { authRole: "anonymous" },
};

export const Logout: Story = {
  ...Sticky,
  args: { authRole: "owner" },
};

export const Unavailable: Story = {
  ...Sticky,
  args: { authUnavailable: true },
};
