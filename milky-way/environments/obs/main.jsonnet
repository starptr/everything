local charts = import '../../charts.jsonnet';

{
  local this = self,

  kubePrometheusStackNS: {
    apiVersion: "v1",
    kind: "Namespace",
    metadata: {
      name: "monitoring",
    },
  },
  kubePrometheusStack: charts.kubePrometheusStack,
}