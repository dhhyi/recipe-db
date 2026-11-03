import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

import "../design.css";

const meta = {
  title: "Blades/Form Elements",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

export const Inputs: Story = {
  render: () => html`
    <main class="container">
      <form>
        <input
          type="text"
          name="ingredient"
          placeholder="Ingredient"
          aria-label="Ingredient"
        />
        <input
          type="url"
          name="inspiration"
          placeholder="Link"
          aria-label="Link"
        />
        <input
          type="search"
          name="q"
          placeholder="Search recipes"
          aria-label="Search recipes"
        />
        <textarea name="method" rows="4" aria-label="Method"></textarea>
        <label for="upload-image">Choose a JPEG or PNG image</label>
        <input id="upload-image" type="file" accept="image/jpeg,image/png" />
      </form>
    </main>
  `,
};

export const Validation: Story = {
  render: () => html`
    <main class="container">
      <form>
        <input
          type="text"
          name="name"
          placeholder="Name"
          aria-label="Name"
          aria-invalid="true"
          aria-describedby="name-helper"
        />
        <small id="name-helper" role="alert">Name must not be empty.</small>
      </form>
    </main>
  `,
};

export const Search: Story = {
  render: () => html`
    <main class="container">
      <form>
        <fieldset role="search">
          <input
            type="search"
            name="q"
            placeholder="Search recipes"
            aria-label="Search recipes"
          />
          <button type="submit" aria-label="Search">
            <svg
              aria-hidden="true"
              focusable="false"
              class="h-3 w-3"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <circle cx="11" cy="11" r="8"></circle>
              <path d="m21 21-4.35-4.35"></path>
            </svg>
          </button>
        </fieldset>
      </form>
    </main>
  `,
};

export const Dropdown: Story = {
  render: () => html`
    <main class="container">
      <details class="dropdown">
        <summary role="button" class="outline">Edit</summary>
        <ul class="markerless">
          <li><a href="#">Edit recipe</a></li>
          <li><a href="#">Edit images</a></li>
        </ul>
      </details>
    </main>
  `,
};

export const Select: Story = {
  render: () => html`
    <main class="container">
      <select name="sort" aria-label="Sort by">
        <option selected>Relevance</option>
        <option>Name</option>
        <option>Newest</option>
        <option>Rating</option>
      </select>
    </main>
  `,
};
