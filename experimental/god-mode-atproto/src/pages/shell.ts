import { type Hole, html } from '../lib/view'

export function shell({ title, content }: { title: string; content: Hole }) {
  return html`<html>
    <head>
      <title>${title}</title>
      <link rel="stylesheet" href="/public/styles.css" />
    </head>
    <body>
      <div id="root">
        <div class="error"></div>
        <div id="header">
          <h1>GodMode</h1>
          <p>Edit your user data in your PDS.</p>
        </div>
        ${content}
      </div>
    </body>
  </html>`
}
