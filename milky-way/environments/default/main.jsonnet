local k = import 'k.libsonnet';
local komgaLib = import 'komga.libsonnet';
local syncthingLib = import 'syncthing.jsonnet';
local retainSC = import 'local-path-retain.jsonnet';
local charts = import '../../charts.jsonnet';
local coredns = import 'coredns.libsonnet';

local komga = komgaLib.new(
  nodeName = 'hydrogen-sulfide',  // Set this to the node where the media is
  hostPathConfig = '/var/lib/rancher/k3s/storage/pvc-4c4ef25f-7260-428d-919c-0c75898aefba_default_komga-config-pvc',
  hostPathData = '/var/lib/rancher/k3s/storage/pvc-ef5457f0-aae6-41c8-8924-d4a0770a5e9d_default_komga-data-pvc',
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
  #komga: komga,
  #syncthing: syncthingLib.new(
  #  nodeName = 'hydrogen-sulfide',
  #  hostPathConfig = '/var/lib/rancher/k3s/storage/pvc-48fabed9-b3e4-46c6-b31b-75c05b012730_default_syncthing-config-syncthing-0',
  #  extraVolumeMounts = [
  #    {
  #      name: 'komga-data',
  #      mountPath: '/data/komga',
  #    },
  #  ],
  #  extraVolumes = [
  #    {
  #      name: 'komga-data',
  #      persistentVolumeClaim: {
  #        claimName: komga.dataPVC.metadata.name,
  #      },
  #    },
  #  ],
  #),
}
