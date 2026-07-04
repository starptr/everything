// @ts-check
import { defineConfig, passthroughImageService } from 'astro/config';

// The frontend shell is a type-agnostic static outline; type-specific behavior lives in
// client-side islands loaded via the build-time registry (src/generated/island-registry.ts).
// cp-frontend serves this static build from CP_WEB_DIR. See DESIGN §9/§11.
//
// A real deployment would add a server/hybrid adapter so channel routes render on demand; the
// scaffold is fully static and resolves channels client-side.
export default defineConfig({
  // No `sharp`: the scaffold has no images, and passthrough keeps the pnpm closure free of a native
  // dependency that would need network/compilation inside the Nix build sandbox.
  image: { service: passthroughImageService() },
});
