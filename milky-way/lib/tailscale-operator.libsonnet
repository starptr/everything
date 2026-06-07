local utils = import 'milky-way/lib/utils.libsonnet';
local vendoredOperatorManifest = importstr 'milky-way/lib/tailscale-operator/operator.yaml';
{
  new(
    client_id,
    client_secret,
  ):: (
    local resources = [
      if resource.kind == 'Secret' && resource.metadata.name == 'operator-oauth' then
        resource {
          stringData+: {
            client_id: client_id,
            client_secret: client_secret,
          },
        }
      else
        resource
      for resource in std.parseYaml(vendoredOperatorManifest)
    ];
    utils.assertAndReturn(
      resources,
      function(rs) std.length(std.filter(
        function(r) r.kind == 'Secret' && r.metadata.name == 'operator-oauth', rs
      )) == 1,
      'expected exactly one operator-oauth Secret in the vendored manifest',
    )
  ),
}
