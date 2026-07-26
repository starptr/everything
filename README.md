# Everything

This monorepo contains many things, including
- Tilderef setup,
- The Milky-Way k3s cluster manifests,
- Pulumi infrastructure declarations,
- NixOS modules,

and more. Some advantages of using a monorepo is that
- Dependencies between these projects are easier to manage and update (eg. a single source of truth is easily depended on by everything else),
- Build systems can be re-used instead of duplicated for each git repository,

etc.
