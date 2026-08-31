import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

import "../design.css";

const meta = {
  title: "Blades/Modal",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

export const Open: Story = {
  render: () => html`
    <dialog open>
      <article>
        <header>
          <button type="button" aria-label="Close" rel="prev"></button>
          <h3>Publish recipe?</h3>
        </header>
        <p>
          This recipe will appear in the shared collection and can be added to
          meal plans.
        </p>
        <footer>
          <button type="button" class="secondary">Cancel</button>
          <button type="button">Publish</button>
        </footer>
      </article>
    </dialog>
  `,
};

export const WithForm: Story = {
  render: () => html`
    <dialog open>
      <article>
        <header>
          <a href="#" aria-label="Close" rel="prev"></a>
          <h3>Add ingredient</h3>
        </header>
        <form>
          <label>
            Ingredient
            <input
              name="ingredient"
              placeholder="Ingredient"
              autocomplete="off"
            />
          </label>
          <label>
            Quantity
            <input name="quantity" placeholder="Quantity" autocomplete="off" />
          </label>
        </form>
        <footer>
          <a href="#" role="button" class="secondary">Cancel</a>
          <a href="#" role="button">Add</a>
        </footer>
      </article>
    </dialog>
  `,
};
