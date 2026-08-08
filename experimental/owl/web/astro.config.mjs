// @ts-check
import { defineConfig, passthroughImageService } from 'astro/config';

// Fully static output (no SSR adapter). The passthrough image service keeps the
// npm closure free of sharp/libvips so the Nix build stays hermetic (same reason
// as channel-party/web). All highlighting/markdown happens at build time; the
// deployed site is plain HTML + CSS.
export default defineConfig({
  image: { service: passthroughImageService() },
});
