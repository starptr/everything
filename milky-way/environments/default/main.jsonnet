local k = import 'k.libsonnet';
local komgaLib = import 'komga.libsonnet';
local syncthingLib = import 'syncthing.jsonnet';
local retainSC = import 'local-path-retain.jsonnet';
local charts = import '../../charts.jsonnet';
local coredns = import 'coredns.libsonnet';

local komga = komgaLib.new(
  nodeName = 'hydrogen-sulfide',  // Set this to the node where the media is
);

{
  local this = self,
  # Nginx ingress controller is not used in this environment, but can be added if needed.
  #ingressNginxNS: {
  #  apiVersion: k.std.apiVersion.core,
  #  kind: "Namespace",
  #  metadata: {
  #    name: "ingress-nginx",
  #  },
  #},
  #nginx: charts.nginx,
  kubePrometheusStackNS: {
    apiVersion: "v1",
    kind: "Namespace",
    metadata: {
      name: "monitoring",
    },
  },
  kubePrometheusStack: charts.kubePrometheusStack,
  myLocalPathRetainSC: retainSC.storageClass,
  coredns: coredns.new(), // TODO: specify nodeSelector and label nodes that should have the DNS
  komga: komga,
  syncthing: syncthingLib.new(
    nodeName = 'hydrogen-sulfide',
    extraVolumeMounts = [
      {
        name: 'komga-data',
        mountPath: '/data/komga',
      },
    ],
    extraVolumes = [
      {
        name: 'komga-data',
        persistentVolumeClaim: {
          claimName: komga.dataPVC.metadata.name,
        },
      },
    ],
  ),
}
