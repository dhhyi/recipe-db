import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html, nothing } from "lit";

import "../design.css";

const meta = {
  title: "Blades/Dialog",
  tags: ["autodocs"],
} satisfies Meta;

export default meta;
type Story = StoryObj;

const editorDialog = (id: string, withActions: boolean) => html`
  <main class="container">
    <button type="button" command="show-modal" commandfor=${id}>
      Open dialog
    </button>
    <dialog id=${id} aria-labelledby="${id}-title" closedby="any">
      <article>
        <header>
          <button
            type="button"
            rel="prev"
            aria-label="Close"
            command="close"
            commandfor=${id}
          ></button>
          <h2 id="${id}-title">Example dialog</h2>
        </header>
        <p>This is an example of a standard dialog.</p>
        ${
          withActions
            ? html`
                <footer>
                  <button
                    type="button"
                    class="outline"
                    command="close"
                    commandfor=${id}
                  >
                    Cancel
                  </button>
                  <button type="button" command="close" commandfor=${id}>
                    OK
                  </button>
                </footer>
              `
            : nothing
        }
      </article>
    </dialog>
  </main>
`;

export const HeaderOnly: Story = {
  render: () => editorDialog("editor-dialog", false),
};

export const WithFooterActions: Story = {
  render: () => editorDialog("editor-dialog-with-actions", true),
};
