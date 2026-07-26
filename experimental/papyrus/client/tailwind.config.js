/** @type {import('tailwindcss').Config} */

// Semantic color tokens are backed by CSS variables (RGB channels) defined per
// theme in src/index.css, so every utility (`bg-canvas`, `text-content`,
// `bg-inverse`, …) re-themes when <html data-theme> flips. The `<alpha-value>`
// placeholder keeps opacity modifiers (`bg-content/10`) working.
const token = (name) => `rgb(var(--color-${name}) / <alpha-value>)`;

export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  // Dark mode keys off the active theme's polarity rather than the OS, so `dark:`
  // stays available as an escape hatch alongside the token system.
  darkMode: ['selector', '[data-theme="dark"]'],
  theme: {
    extend: {
      colors: {
        'canvas': {
          DEFAULT: token('canvas'),
          dark: token('canvas-dark'),
          light: token('canvas-light'),
          lighter: token('canvas-lighter'),
        },
        'surface': {
          DEFAULT: token('surface'),
          hover: token('surface-hover'),
          active: token('surface-active'),
        },
        'border': {
          DEFAULT: token('border'),
          light: token('border-light'),
          strong: token('border-strong'),
        },
        // Foreground/text scale (primary → faint).
        'content': {
          DEFAULT: token('content'),
          muted: token('content-muted'),
          subtle: token('content-subtle'),
          faint: token('content-faint'),
        },
        // Filled buttons that invert against the canvas (was `bg-white text-canvas`).
        'inverse': {
          DEFAULT: token('inverse'),
          content: token('inverse-content'),
        },
        // Popover/menu chrome.
        'popover': {
          DEFAULT: token('popover'),
          border: token('popover-border'),
        },
      },
      fontFamily: {
        sans: ['Inter', 'system-ui', '-apple-system', 'sans-serif'],
        mono: ['"JetBrains Mono"', '"Fira Code"', '"SF Mono"', 'monospace'],
      },
      boxShadow: {
        'node': '0 2px 8px rgba(0, 0, 0, 0.3)',
        'node-hover': '0 4px 16px rgba(0, 0, 0, 0.4)',
        'glow': '0 0 20px var(--glow-color)',
      }
    },
  },
  plugins: [],
}
