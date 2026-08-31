import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

import "../design.css";

const meta = {
  title: "Blades/Form Elements",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

export const Form: Story = {
  render: () => html`
    <main class="container">
      <form>
        <fieldset>
          <label>
            Recipe name
            <input
              name="recipe_name"
              placeholder="Recipe name"
              autocomplete="off"
            />
          </label>
          <label>
            Email
            <input
              type="email"
              name="email"
              placeholder="Email"
              autocomplete="email"
            />
          </label>
        </fieldset>
        <input type="submit" value="Save recipe" />
      </form>
    </main>
  `,
};

export const Inputs: Story = {
  render: () => html`
    <main class="container">
      <form>
        <input type="text" name="text" placeholder="Text" aria-label="Text" />
        <input
          type="email"
          name="email"
          placeholder="Email"
          aria-label="Email"
          autocomplete="email"
        />
        <input
          type="search"
          name="search"
          placeholder="Search"
          aria-label="Search"
        />
        <input
          type="number"
          name="servings"
          placeholder="Servings"
          aria-label="Servings"
        />
        <input type="date" name="date" aria-label="Date" />
        <input type="color" value="#0a750f" aria-label="Color picker" />
        <input type="file" aria-label="Recipe photo" />
      </form>
    </main>
  `,
};

export const TextareaAndSelect: Story = {
  render: () => html`
    <main class="container">
      <form>
        <label>
          Notes
          <textarea name="notes" placeholder="Prep notes"></textarea>
        </label>
        <label>
          Cuisine
          <select name="cuisine" required>
            <option value="" selected disabled>Select cuisine</option>
            <option>Italian</option>
            <option>Japanese</option>
            <option>Indian</option>
            <option>Thai</option>
          </select>
        </label>
      </form>
    </main>
  `,
};

export const ChecksRadiosAndSwitches: Story = {
  render: () => html`
    <main class="container">
      <form>
        <fieldset>
          <legend>Dietary tags</legend>
          <label><input type="checkbox" name="vegetarian" />Vegetarian</label>
          <label
            ><input type="checkbox" name="gluten_free" checked />Gluten
            free</label
          >
        </fieldset>
        <fieldset>
          <legend>Difficulty</legend>
          <label
            ><input
              type="radio"
              name="difficulty"
              value="easy"
              checked
            />Easy</label
          >
          <label
            ><input
              type="radio"
              name="difficulty"
              value="medium"
            />Medium</label
          >
          <label
            ><input type="radio" name="difficulty" value="hard" />Hard</label
          >
        </fieldset>
        <fieldset>
          <label
            ><input
              type="checkbox"
              role="switch"
              name="published"
              checked
            />Published</label
          >
          <label
            ><input
              type="checkbox"
              role="switch"
              name="featured"
            />Featured</label
          >
        </fieldset>
      </form>
    </main>
  `,
};

export const ValidationAndHelperText: Story = {
  render: () => html`
    <main class="container">
      <form>
        <input
          type="text"
          name="valid"
          value="Roasted squash pasta"
          aria-invalid="false"
          aria-describedby="valid-helper"
        />
        <small id="valid-helper">Looks good.</small>
        <input
          type="text"
          name="invalid"
          value="Untitled"
          aria-invalid="true"
          aria-describedby="invalid-helper"
        />
        <small id="invalid-helper"
          >Please provide a more descriptive title.</small
        >
      </form>
    </main>
  `,
};

export const Grouped: Story = {
  render: () => html`
    <main class="container">
      <form>
        <fieldset role="group">
          <input
            type="search"
            name="query"
            placeholder="Search recipes"
            aria-label="Search recipes"
          />
          <input type="submit" value="Search" />
        </fieldset>
      </form>
    </main>
  `,
};

export const FloatLabels: Story = {
  render: () => html`
    <main class="container">
      <form>
        <fieldset>
          <label>
            <span>Name</span>
            <input name="name" placeholder="First Last" />
          </label>
          <label>
            <span>Bio</span>
            <textarea name="bio" placeholder="Tell your story"></textarea>
          </label>
          <label>
            <span>Cuisine</span>
            <select name="cuisine">
              <option selected disabled>Select</option>
              <option>Italian</option>
              <option>Japanese</option>
              <option>Indian</option>
              <option>Thai</option>
            </select>
          </label>
        </fieldset>
      </form>
    </main>
  `,
};
