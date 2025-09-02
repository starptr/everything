local tanka = import "github.com/grafana/jsonnet-libs/tanka-util/main.libsonnet";
local helm = tanka.helm.new(std.thisFile);

{
  nginx: helm.template("ingress-nginx", "./charts/ingress-nginx", {
    namespace: "ingress-nginx",
    values: {
      persistence: { enabled: true },
      controller: {
        service: {
          type: "ClusterIP",
        },
        config: {
          allowSnippetAnnotations: true,
        },
        allowSnippetAnnotations: true,
      },
    },
  }),
}