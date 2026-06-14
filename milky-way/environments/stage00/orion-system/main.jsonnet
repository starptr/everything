local zfsIscsiDriverConfig = import 'milky-way/environments/stage00/orion-system/my-custom-zfs-iscsi-democratic-csi-driver-config.jsonnet';
local zfsNfsDriverConfig = import 'milky-way/environments/stage00/orion-system/my-custom-zfs-nfs-democratic-csi-driver-config.jsonnet';
local charts = import 'milky-way/charts.jsonnet';
local httpEcho = import 'milky-way/lib/http-echo.libsonnet';
local exampleZfsGenericIscsi = import 'milky-way/lib/example-zfs-generic-iscsi.libsonnet';
local kataRuntimeClass = import 'milky-way/lib/kata-runtime-class.libsonnet';
local kataMicrovmTest = import 'milky-way/lib/kata-microvm-test.libsonnet';
local calibreWebAuto = import 'milky-way/lib/calibre-web-automated.libsonnet';
local ddnsUpdater = import 'milky-way/lib/ddns-updater.libsonnet';
local traefik = import 'milky-way/lib/traefik.libsonnet';
local tailscaleOperator = import 'milky-way/lib/tailscale-operator.libsonnet';
local testTailscaleIngress = import 'milky-way/lib/test-tailscale-operator-ingress.libsonnet';
local testTailscaleL3 = import 'milky-way/lib/test-tailscale-operator-network-L3.libsonnet';
local openclaw = import 'milky-way/lib/openclaw.libsonnet';
local qbittorrent = import 'milky-way/lib/qbittorrent.libsonnet';
local gluetunLeakTest = import 'milky-way/lib/gluetun-leak-test.libsonnet';
local testExampleWhaleImageDigest = import 'milky-way/lib/test-example-whale-image-digest.libsonnet';
local secrets = import 'milky-way/secrets/k8s-secret-values.jsonnet';
{
  local this = self,
  local mdataPvcName = 'mdata',
  democraticCsiNamespace: {
    apiVersion: "v1",
    kind: "Namespace",
    metadata: {
      name: "democratic-csi",
    },
  },
  zfsIscsiDriver: charts.zfs_iscsi,
  zfsNfsDriver: charts.zfs_nfs,
  "my-custom-zfs-iscsi-democratic-csi-driver-config": {
    apiVersion: "v1",
    kind: "Secret",
    metadata: {
      name: "my-custom-zfs-iscsi-democratic-csi-driver-config",
      namespace: "democratic-csi",
    },
    type: "Opaque",
    data: {
      "driver-config-file.yaml": std.base64(std.manifestYamlDoc(zfsIscsiDriverConfig)),
    },
  },
  "my-custom-zfs-nfs-democratic-csi-driver-config": {
    apiVersion: "v1",
    kind: "Secret",
    metadata: {
      name: "my-custom-zfs-nfs-democratic-csi-driver-config",
      namespace: "democratic-csi",
    },
    type: "Opaque",
    data: {
      "driver-config-file.yaml": std.base64(std.manifestYamlDoc(zfsNfsDriverConfig)),
    },
  },
  testingNamespace: {
    apiVersion: "v1",
    kind: "Namespace",
    metadata: {
      name: "test-k8s",
    },
  },
  httpEcho: httpEcho.new(),
  exampleZfsGenericIscsi: exampleZfsGenericIscsi.new(storageClassName="my-custom-zfs-generic-iscsi"),
  // TODO: rename lib
  exampleZfsNfs: exampleZfsGenericIscsi.new(
    storageClassName="my-custom-zfs-generic-nfs-csi",
    name="nfs-test",
  ),
  kataRuntimeClass: kataRuntimeClass.runtimeClass,
  kataMicrovmTest: kataMicrovmTest.new(),
  testExampleWhaleImageDigest: testExampleWhaleImageDigest.new(),
  calibreWebAuto: calibreWebAuto.new(domain="cwa-methanol.local"),

  ddnsUpdater: ddnsUpdater.new(
    config={
      settings: [
        {
          provider: "cloudflare",
          zone_identifier: secrets.ddnsUpdater.cloudflare.zone_identifier,
          domain: "carless-drivers-ddns.andref.app",
          ttl: 1,
          token: secrets.ddnsUpdater.cloudflare.token,
          ip_version: "ipv4",
          # Proxy gives the domain an SSL cert for free
          proxied: true,
        },
      ],
    },
    domain="carless-drivers-ddns.andref.app",
  ),

  tailscaleOperator: tailscaleOperator.new(
    client_id = secrets.tailscaleOperatorTrustCredentials.orionSystem.client_id,
    client_secret = secrets.tailscaleOperatorTrustCredentials.orionSystem.client_secret,
    operatorTags = 'tag:k8s-orion-system-operator',
    proxyTags = 'tag:k8s-orion-system',
  ),

  testTailscaleIngress: testTailscaleIngress.new(),

  testTailscaleL3: testTailscaleL3.new(),

  openclaw: openclaw.new(
    gatewayToken = secrets.openclaw.OPENCLAW_GATEWAY_TOKEN,
    geminiApiKey = secrets.openclaw.GEMINI_API_KEY,
    tailnet = "tail4c9a",
  ),

  // Shared media library volume. Apps mount this whole PVC and hardlink between subdirs
  // (e.g. qbittorrent writes downloads/qbittorrent/, *arr apps hardlink into a library/ tree).
  // Hardlinks require a single filesystem, so everything that shares files mounts this one PVC.
  mdataPvc: {
    apiVersion: "v1",
    kind: "PersistentVolumeClaim",
    metadata: { name: mdataPvcName, namespace: "default" },
    spec: {
      accessModes: ["ReadWriteMany"],
      storageClassName: "my-custom-zfs-generic-nfs-csi",
      resources: { requests: { storage: "1Ti" } },
    },
  },

  // Headless qbittorrent whose traffic is forced through a NordVPN/WireGuard tunnel by an embedded
  // gluetun sidecar killswitch (lib/gluetun.libsonnet). WebUI via Tailscale L7 ingress. Downloads
  // land in downloads/qbittorrent/ on the shared mdata volume (mounted at /data).
  qbittorrent: qbittorrent.new(
    wireguardPrivateKey = secrets.vpn.wireguard[0].privateKey,
    tailscaleHostname = "qbittorrent",
    serverCountries = "United States",
    mediaClaimName = mdataPvcName,
  ),

  // Continuously asserts qbittorrent's egress is the VPN exit (not the home IP) and exercises a real
  // ipleak.net torrent magnet; crashloops on a detected leak.
  gluetunLeakTest: gluetunLeakTest.new(),

  cilium: charts.cilium,

  traefikConfig: traefik.reconfigForCilium(),
}