// @ts-check
import { defineConfig, passthroughImageService } from 'astro/config';

// The frontend shell is a type-agnostic static outline; type-specific behavior lives in
// client-side islands loaded via the build-time registry (src/generated/island-registry.ts).
// cp-frontend serves this static build from CP_WEB_DIR. See DESIGN §9/§11.
//
// Output stays fully static (no SSR adapter): Astro static mode can't prerender an arbitrary
// /channels/<id>, so routing is client-side — cp-frontend falls back to index.html for unknown paths
// and the shell reads location.pathname to mount the channel's island. This keeps the Rust server a
// plain static file server. Revisit if per-request server rendering is ever needed (DESIGN §16/#16).
export default defineConfig({
  // No `sharp`: the scaffold has no images, and passthrough keeps the pnpm closure free of a native
  // dependency that would need network/compilation inside the Nix build sandbox.
  image: { service: passthroughImageService() },
});
