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
    authEmail: "",
    authEnabled: false,
  },
  argTypes: {
    authRole: {
      control: "select",
      options: ["", "anonymous", "member", "owner"],
    },
    authEmail: { control: "text" },
    authEnabled: { control: "boolean" },
  },
} satisfies Meta;

export default meta;
type Story = StoryObj;

const lorem = new LoremIpsum();

export const Sticky: Story = {
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement);
    await waitFor(() => {
      const login = canvas.queryByRole("link", { name: "Anmelden" });
      const dropdown = canvasElement.querySelector("details.dropdown");
      expect(!!login).toBe(args.authRole === "anonymous" && args.authEnabled);
      expect(!!dropdown).toBe(
        args.authEnabled && !!args.authRole && args.authRole !== "anonymous",
      );
      if (dropdown) {
        expect(dropdown.querySelector("summary")).toHaveAccessibleName(
          "Profil",
        );
        expect(dropdown.querySelector("summary")).toHaveTextContent("Profil");
        expect(
          dropdown.querySelector('a[href="/oauth2/sign_out?rd=%2F"]'),
        ).toHaveTextContent("Abmelden");
      }
    });
  },
  render: ({ authRole, authEmail, authEnabled }) => html`
    <header-component
      auth-role=${authRole}
      auth-email=${authEmail}
      ?auth-enabled=${authEnabled}
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

export const LoggedOut: Story = {
  ...Sticky,
  args: { authRole: "anonymous", authEnabled: true },
};

export const AnonymousWithoutGoogle: Story = {
  ...Sticky,
  args: { authRole: "anonymous", authEnabled: false },
};

export const LoggedIn: Story = {
  ...Sticky,
  args: {
    authRole: "owner",
    authEmail: "max.mustermann@example.com",
    authEnabled: true,
  },
};
