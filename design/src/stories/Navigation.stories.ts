import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

import "../design.css";

const meta = {
  title: "Blades/Navigation",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

export const Basic: Story = {
  render: () => html`
    <main class="container">
      <nav>
        <ul>
          <li><strong>Recipe DB</strong></li>
        </ul>
        <ul>
          <li><a href="#">Recipes</a></li>
          <li><a href="#">Ingredients</a></li>
          <li><a href="#">Meal plans</a></li>
        </ul>
      </nav>
    </main>
  `,
};

export const WithActions: Story = {
  render: () => html`
    <main class="container">
      <nav>
        <ul>
          <li><strong>Recipe DB</strong></li>
        </ul>
        <ul>
          <li><a href="#" class="secondary">Import</a></li>
          <li><button type="button" class="secondary">New recipe</button></li>
        </ul>
      </nav>
    </main>
  `,
};

export const WithDropdown: Story = {
  render: () => html`
    <main class="container">
      <nav>
        <ul>
          <li><strong>Recipe DB</strong></li>
        </ul>
        <ul>
          <li><a href="#" class="secondary">Collections</a></li>
          <li>
            <details class="dropdown">
              <summary>Account</summary>
              <ul dir="rtl">
                <li><a href="#">Profile</a></li>
                <li><a href="#">Settings</a></li>
                <li><a href="#">Log out</a></li>
              </ul>
            </details>
          </li>
        </ul>
      </nav>
    </main>
  `,
};

export const Breadcrumb: Story = {
  render: () => html`
    <main class="container">
      <nav aria-label="breadcrumb">
        <ul>
          <li><a href="#">Home</a></li>
          <li><a href="#">Recipes</a></li>
          <li>Roasted squash pasta</li>
        </ul>
      </nav>
    </main>
  `,
};
