import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

import "../design.css";

const meta = {
  title: "Blades/Dropdowns",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

const menuItems = html`
  <ul>
    <li><a href="#">Breakfast</a></li>
    <li><a href="#">Lunch</a></li>
    <li><a href="#">Dinner</a></li>
    <li><a href="#">Dessert</a></li>
  </ul>
`;

export const SelectLike: Story = {
  render: () => html`
    <main class="container">
      <section class="grid" aria-label="Dropdown and select">
        <details class="dropdown">
          <summary>Choose a collection</summary>
          ${menuItems}
        </details>
        <select name="collection" aria-label="Collection" required>
          <option value="" selected disabled>Choose a collection</option>
          <option>Breakfast</option>
          <option>Lunch</option>
          <option>Dinner</option>
          <option>Dessert</option>
        </select>
      </section>
    </main>
  `,
};

export const ButtonVariants: Story = {
  render: () => html`
    <main class="container">
      <section class="grid" aria-label="Dropdown button variants">
        <details class="dropdown">
          <summary role="button">Primary</summary>
          ${menuItems}
        </details>
        <details class="dropdown">
          <summary role="button" class="secondary">Secondary</summary>
          ${menuItems}
        </details>
        <details class="dropdown">
          <summary role="button" class="outline contrast">Outline</summary>
          ${menuItems}
        </details>
      </section>
    </main>
  `,
};

export const WithChecks: Story = {
  render: () => html`
    <main class="container">
      <details class="dropdown">
        <summary>Select dietary tags</summary>
        <ul>
          <li>
            <label><input type="checkbox" name="vegetarian" />Vegetarian</label>
          </li>
          <li>
            <label
              ><input type="checkbox" name="freezer" />Freezer friendly</label
            >
          </li>
          <li>
            <label
              ><input type="checkbox" name="quick" />Under 30 minutes</label
            >
          </li>
        </ul>
      </details>
    </main>
  `,
};
