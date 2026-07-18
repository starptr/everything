// Second preload (after happydom.ts registers the DOM): Testing Library matchers,
// per-test cleanup, and a synchronous framer-motion so exit animations never defer
// DOM removal (present/absent assertions stay deterministic).
import { afterEach, expect, mock } from "bun:test";
import { cleanup } from "@testing-library/react";
import * as matchers from "@testing-library/jest-dom/matchers";
import { createElement } from "react";

expect.extend(matchers);
afterEach(() => cleanup());

// AnimatePresence -> passthrough; motion.* -> plain tag (animation-only props
// stripped to avoid React "unknown prop" warnings).
mock.module("framer-motion", () => ({
  AnimatePresence: ({ children }: any) => children,
  motion: new Proxy({} as any, {
    get:
      (_t, tag: string) =>
      ({
        children,
        initial,
        animate,
        exit,
        transition,
        layout,
        variants,
        whileHover,
        whileTap,
        ...rest
      }: any) =>
        createElement(tag, rest, children),
  }),
}));
