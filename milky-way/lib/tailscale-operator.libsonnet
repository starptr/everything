local utils = import 'milky-way/lib/utils.libsonnet';
local vendoredOperatorManifest = importstr 'milky-way/lib/tailscale-operator/operator.yaml';
{
  new(
    client_id,
    client_secret,
    operatorTags,  // tag the operator authenticates itself with
    proxyTags,  // tag applied to the resources the operator manages
  ):: (
    local envOverrides = {
      OPERATOR_INITIAL_TAGS: operatorTags,
      PROXY_TAGS: proxyTags,
    };
    local resources = [
      if resource.kind == 'Secret' && resource.metadata.name == 'operator-oauth' then
        resource {
          stringData+: {
            client_id: client_id,
            client_secret: client_secret,
          },
        }
      else if resource.kind == 'Deployment' && resource.metadata.name == 'operator' then
        resource {
          spec+: { template+: { spec+: { containers: std.map(
            function(container) container {
              env: std.map(
                function(e) if std.objectHas(envOverrides, e.name) then e { value: envOverrides[e.name] } else e,
                container.env,
              ),
            },
            super.containers,
          ) } } },
        }
      else
        resource
      for resource in std.parseYaml(vendoredOperatorManifest)
    ];
    utils.assertAndReturn(
      utils.assertAndReturn(
        resources,
        function(rs) std.length(std.filter(
          function(r) r.kind == 'Secret' && r.metadata.name == 'operator-oauth', rs
        )) == 1,
        'expected exactly one operator-oauth Secret in the vendored manifest',
      ),
      function(rs) std.length(std.filter(
        function(r) r.kind == 'Deployment' && r.metadata.name == 'operator', rs
      )) == 1,
      'expected exactly one operator Deployment in the vendored manifest',
    )
  ),
}
