import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

import "../design.css";

const meta = {
  title: "Blades/Tables",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

const pantryRows = html`
  <tr>
    <th scope="row">Flour</th>
    <td>2 kg</td>
    <td>Pantry</td>
    <td>High</td>
  </tr>
  <tr>
    <th scope="row">Eggs</th>
    <td>12</td>
    <td>Fridge</td>
    <td>Medium</td>
  </tr>
  <tr>
    <th scope="row">Tomatoes</th>
    <td>8</td>
    <td>Counter</td>
    <td>Low</td>
  </tr>
`;

export const Basic: Story = {
  render: () => html`
    <main class="container">
      <div class="overflow-auto">
        <table>
          <caption>
            Pantry inventory
          </caption>
          <thead>
            <tr>
              <th scope="col">Item</th>
              <th scope="col">Amount</th>
              <th scope="col">Storage</th>
              <th scope="col">Priority</th>
            </tr>
          </thead>
          <tbody>
            ${pantryRows}
          </tbody>
          <tfoot>
            <tr>
              <th scope="row">Total tracked</th>
              <td colspan="3">3 ingredients</td>
            </tr>
          </tfoot>
        </table>
      </div>
    </main>
  `,
};

export const Striped: Story = {
  render: () => html`
    <main class="container">
      <div class="overflow-auto">
        <table class="striped">
          <thead>
            <tr>
              <th scope="col">Item</th>
              <th scope="col">Amount</th>
              <th scope="col">Storage</th>
              <th scope="col">Priority</th>
            </tr>
          </thead>
          <tbody>
            ${pantryRows}
          </tbody>
        </table>
      </div>
    </main>
  `,
};

export const Borderless: Story = {
  render: () => html`
    <main class="container">
      <table class="borderless">
        <thead>
          <tr>
            <th>Recipe</th>
            <th>Status</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>Roasted squash pasta</td>
            <td>Ready</td>
          </tr>
          <tr>
            <td>Lentil soup</td>
            <td>Testing</td>
          </tr>
        </tbody>
      </table>
    </main>
  `,
};

export const ThemedHeader: Story = {
  render: () => html`
    <main class="container">
      <div class="overflow-auto">
        <table>
          <thead data-theme="dark">
            <tr>
              <th scope="col">Item</th>
              <th scope="col">Amount</th>
              <th scope="col">Storage</th>
              <th scope="col">Priority</th>
            </tr>
          </thead>
          <tbody>
            ${pantryRows}
          </tbody>
        </table>
      </div>
    </main>
  `,
};
