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
local sonarr = import 'milky-way/lib/sonarr.libsonnet';
local prowlarr = import 'milky-way/lib/prowlarr.libsonnet';
local buildarr = import 'milky-way/lib/buildarr.libsonnet';
local utils = import 'milky-way/lib/utils.libsonnet';
local wgConf = import 'milky-way/lib/wireguard-conf.libsonnet';
local sftp = import 'milky-way/lib/sftp.libsonnet';
local grandCentral = import 'milky-way/lib/grand-central.libsonnet';
local gluetunLeakTest = import 'milky-way/lib/gluetun-leak-test.libsonnet';
local testExampleWhaleImageDigest = import 'milky-way/lib/test-example-whale-image-digest.libsonnet';
local secrets = import 'milky-way/secrets/k8s-secret-values.jsonnet';
{
  local this = self,
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
          domain: "carless-drivers-cfproxied-ddns.andref.app",
          ttl: 1,
          token: secrets.ddnsUpdater.cloudflare.token,
          ip_version: "ipv4",
          # Proxy gives the domain an SSL cert for free
          proxied: true,
        },
        {
          provider: "cloudflare",
          zone_identifier: secrets.ddnsUpdater.cloudflare.zone_identifier,
          domain: "carless-drivers-ddns.andref.app",
          ttl: 1,
          token: secrets.ddnsUpdater.cloudflare.token,
          ip_version: "ipv4",
          # Non-proxied: resolves directly to the home IP (no Cloudflare SSL/proxy).
          proxied: false,
        },
      ],
    },
    webuiEndpointDomain="carless-drivers-cfproxied-ddns.andref.app",
  ),

  tailscaleOperator: tailscaleOperator.new(
    client_id = secrets.tailscaleOperatorTrustCredentials.orionSystem.client_id,
    client_secret = secrets.tailscaleOperatorTrustCredentials.orionSystem.client_secret,
    operatorTags = 'tag:k8s-orion-system-operator',
    proxyTags = 'tag:k8s-orion-system',
  ),

  testTailscaleIngress: testTailscaleIngress.new(tailscaleHostname = "test-ts-ingress"),

  testTailscaleL3: testTailscaleL3.new(tailscaleHostname = "test-ts-l3"),

  openclaw: openclaw.new(
    gatewayToken = secrets.openclaw.OPENCLAW_GATEWAY_TOKEN,
    geminiApiKey = secrets.openclaw.GEMINI_API_KEY,
    tailscaleHostname = "openclaw",
    tailnet = "tail4c9a",
  ),

  // Shared media library volume. Apps mount this whole PVC and hardlink between subdirs
  // (e.g. qbittorrent writes downloads/qbittorrent/, *arr apps hardlink into a library/ tree).
  // Hardlinks require a single filesystem, so everything that shares files mounts this one PVC.
  mdataPvc: {
    apiVersion: "v1",
    kind: "PersistentVolumeClaim",
    metadata: { name: "mdata", namespace: "default" },
    spec: {
      accessModes: ["ReadWriteMany"],
      storageClassName: "my-custom-zfs-generic-nfs-csi",
      resources: { requests: { storage: "1Ti" } },
    },
  },

  // Headless qbittorrent whose traffic is forced through a ProtonVPN/WireGuard tunnel by an embedded
  // gluetun sidecar killswitch (lib/gluetun.libsonnet), with NAT-PMP port forwarding so it's
  // connectable for inbound peers (ProtonVPN supports PF; NordVPN does not). WebUI via Tailscale L7
  // ingress. Downloads land in downloads/qbittorrent/ on the shared mdata volume (mounted at /data).
  // The WireGuard key is read straight from the sops-managed ProtonVPN .conf (only Interface.
  // PrivateKey is used; gluetun selects its own PF-capable P2P server).
  qbittorrent: qbittorrent.new(
    wireguardPrivateKey = wgConf.privateKeyOf(importstr 'milky-way/secrets/qbt-gluetun.conf'),
    tailscaleHostname = "qbittorrent",
    vpnProvider = "protonvpn",
    serverCountries = "United States",
    volumeClaimName = this.mdataPvc.metadata.name,
    volumeMountPath = "/data",
    downloadsSubdir = "downloads/qbittorrent",
  ),

  // Sonarr: monitors/grabs TV episodes, hands torrents to qbittorrent
  // (qbittorrent.default.svc.cluster.local:8080), then imports completed downloads by hardlinking
  // them out of /data/downloads/qbittorrent into a library tree (e.g. /data/library/tv) on the
  // SHARED mdata volume -- same PVC, same /data mount path as qbittorrent, so hardlinks/atomic
  // moves stay on one filesystem. WebUI via Tailscale L7 ingress; SQLite config on its own iSCSI
  // RWO PVC. The download-client/indexer links are entered in the UI post-deploy (they need API
  // keys each app generates on first boot).
  sonarr: sonarr.new(
    apiKey = secrets.sonarr.apiKey,
    tailscaleHostname = "sonarr",
    mediaVolumeClaimName = this.mdataPvc.metadata.name,
  ),

  // Prowlarr: indexer manager. No media volume -- it pushes indexer configs to Sonarr
  // (sonarr.default.svc.cluster.local:8989, and later Radarr) over ClusterIP DNS. WebUI via
  // Tailscale L7 ingress; SQLite config on its own iSCSI RWO PVC.
  prowlarr: prowlarr.new(
    apiKey = secrets.prowlarr.apiKey,
    tailscaleHostname = "prowlarr",
  ),

  // Buildarr: declaratively asserts the inter-app links the *arr apps store in SQLite (and which the
  // SONARR__/PROWLARR__ env overrides can't reach) -- Sonarr's qBittorrent download client and
  // Prowlarr's Sonarr application (which auto-syncs Prowlarr's indexers into Sonarr). Plumbing only:
  // the trackers themselves stay manual in Prowlarr, so `delete_unmanaged: false` is set on every
  // managed section AND as a plugin-global default -- Buildarr would otherwise be free to delete
  // resources it doesn't manage. Buildarr has no single master switch for this (it's per-section), so
  // the global blocks cover only the sections we manage; a future edit that manages a NEW section must
  // add its own explicit `delete_unmanaged: false`. NEVER flip any of these to true.
  //
  // This desired-state config is owned HERE (the lib is just the daemon plumbing). Host/port for each
  // app come from its Service (the source of truth): the FQDN via utils.domainOfService, and the
  // webui port as ports[0] after asserting ports[0] really is the webui entry (qbittorrent's Service
  // also exposes gluetun-ctrl). API keys come from sops.
  local buildarrConfig =
    local sonarrOrionSystemInstanceName = 'sonarr-orion-system';
    local prowlarrOrionSystemInstanceName = 'prowlarr-orion-system';
    local httpUrl(hostname, port) = 'http://%s:%d' % [hostname, port];
    {
      buildarr: {
        // Buildarr rolls via the Deployment's checksum/config annotation, not in-place file watch.
        watch_config: false,
      },
      sonarr: {
        // GLOBAL default for all sonarr instances (current + future). MUST stay false -- never
        // clobber download clients added by hand in Sonarr's UI.
        settings: { download_clients: { delete_unmanaged: false } },
        instances: {
          [sonarrOrionSystemInstanceName]: {
            hostname: utils.domainOfService(this.sonarr.service),
            port: utils.assertAndReturn(this.sonarr.service.spec.ports[0], function(p) p.name == 'webui').port,
            protocol: 'http',
            api_key: secrets.sonarr.apiKey,
            settings: {
              download_clients: {
                delete_unmanaged: false,  // also explicit per-instance (belt & suspenders)
                definitions: {
                  qBittorrent: {
                    type: 'qbittorrent',
                    host: utils.domainOfService(this.qbittorrent.service),
                    port: utils.assertAndReturn(this.qbittorrent.service.spec.ports[0], function(p) p.name == 'webui').port,
                    // No username/password: qBittorrent's AuthSubnetWhitelist bypasses auth for
                    // in-cluster callers (Sonarr is in the pod CIDR). See lib/qbittorrent.libsonnet.
                    category: 'tv-sonarr',  // qBittorrent category Sonarr tags its grabs with
                  },
                },
              },
            },
          },
        },
      },
      prowlarr: {
        // GLOBAL default for all prowlarr instances (current + future). MUST stay false -- never
        // clobber apps/indexers added by hand in Prowlarr's UI.
        settings: { apps: { applications: { delete_unmanaged: false } } },
        instances: {
          [prowlarrOrionSystemInstanceName]: {
            hostname: utils.domainOfService(this.prowlarr.service),
            port: utils.assertAndReturn(this.prowlarr.service.spec.ports[0], function(p) p.name == 'webui').port,
            protocol: 'http',
            api_key: secrets.prowlarr.apiKey,
            settings: {
              apps: {
                applications: {
                  delete_unmanaged: false,  // also explicit per-instance (belt & suspenders)
                  definitions: {
                    Sonarr: {
                      type: 'sonarr',
                      // Cross-link by name: Buildarr resolves the Sonarr instance above and fills in
                      // its API key itself. The two URLs are still required explicitly (instance_name
                      // only links the key): prowlarr_url is how Sonarr dials back to Prowlarr for the
                      // indexer proxy; base_url is how Prowlarr reaches Sonarr to push the sync.
                      instance_name: sonarrOrionSystemInstanceName,
                      prowlarr_url: httpUrl(
                        utils.domainOfService(this.prowlarr.service),
                        utils.assertAndReturn(this.prowlarr.service.spec.ports[0], function(p) p.name == 'webui').port,
                      ),
                      base_url: httpUrl(
                        utils.domainOfService(this.sonarr.service),
                        utils.assertAndReturn(this.sonarr.service.spec.ports[0], function(p) p.name == 'webui').port,
                      ),
                      sync_level: 'full_sync',
                    },
                  },
                },
              },
            },
          },
        },
      },
    },
  buildarrConnect: buildarr.new(config = buildarrConfig),

  // Public-key-only SFTP front door onto the shared mdata volume (read-write), reached over the
  // tailnet (mdata-sftp.tail4c9a.ts.net:22) and over the LAN via methanol's mDNS alias
  // (mdata-methanol.local:30022 -- alias + firewall port live in venus methanol.nix). Authorized
  // identities: sodium's key and the 1Password key (public keys, mirrored from methanol.nix).
  mdataSftp: sftp.new(
    claimName = this.mdataPvc.metadata.name,
    name = "mdata-sftp",
    tailscaleHostname = "mdata-sftp",
    sftpUser = "mdata",
    nodePort = 30022,
    authorizedKeys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDLrT2/gQXhOz4E4xSphB8EXouild5qNOnZ6ZVXuTnf167z8xxSB10mxNey2gKDaIVig6I/tRFeYy6/N/QutbBlKI/+GNPjGCcVJI0hf7fTZGL4caTW8ggcXRz4LAsFp3JBf6Li0FVrGz5ojD0Etbl54BDn033q/tlVRhme5bXJ6s73yRg04kqdQsWVBRJwyzbUUmCQPrZd9i5Nh4QFVuhZljEyUWIStajE+c9v8OOiY1svv+XjKBjyWphP16HqgzvnEDf5+MQ5AUxE05IvJx43UY43CKTe3evzt4F/IqSdYwYGIQ55DaseRmf5zmHLU8MTTkksmOPQEzJL0nBzAmxyGV3PsMYPoIN+1/gJmxCO6ZaaCxYr9SFK/yoRW5e0PFX433xPhNsITBq7jUrVg6BQ/lr0ntRfvd7pRhFq8v02R3jWokL/99skxp1kjVF42bXEJXYPpHF3XAUhYscjOwmWj8dJgsIsSIKIjh7gRVYxQGrZQXOcJQjMytFgXy7fWHM= yuto@Yutos-MacBook-Pro.local",  // Yuto's Sodium
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPtVvX9uhSWD1DPBIRqgkNzFXqjdqvWB/WtDy4seaiJl",  // 1Password "ssh key - main"
    ],
  ),

  // One-stop-shop SSH jump bastion for reaching my personal machines (lib/grand-central.libsonnet).
  // Reached publicly at grand-central.yuto.sh -> CNAME carless-drivers-ddns.andref.app (the
  // NON-proxied ddns record above, so it resolves straight to the home IP -- Cloudflare's proxy
  // can't carry raw SSH) -> home router forwards WAN 30023 -> this NodePort on methanol.
  //
  // ONE list of authorized participant keys (no client/target split). An entry is a bare pubkey
  // string (may open a reverse listener on any loopback port + reach any target), or
  // { key, listenPorts: [..] } pinning which port(s) it may register a reverse listener on. A
  // machine becomes reachable by running its own reverse-tunnel agent on its assigned port (e.g.
  // Sodium's launchd `-R localhost:2222`); add future targets on distinct ports.
  grandCentral: grandCentral.new(
    nodePort = 30023,
    authorizedKeys = [
      // Sodium -- a target pinned to its reverse-listener port 2222 (launchd agent in venus
      // sodium.nix; tunnel priv key in sops secrets/personal/grand-central-tunnel.json).
      { key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBWjndergDSUeNxqTByOVeon92N6X52NaNydd4XUXR2A grand-central-tunnel-sodium", listenPorts: [2222] },
      // magnesium-hydroxide -- a client (also in Sodium's inbound authorized_keys for the final
      // hop). Bare string: may reach any target, no edits here when targets are added.
      //
      // Screen Share INTO Sodium from this client (Standard mode only; VNC rides the ssh jump):
      //   ssh -i ~/.ssh/grand-central -o IdentitiesOnly=yes \
      //       -o ProxyCommand="ssh -i ~/.ssh/grand-central -o IdentitiesOnly=yes -W %h:%p -p 30023 relay@grand-central.yuto.sh" \
      //       -L 5901:127.0.0.1:5900 -p 2222 yuto@localhost
      //   open vnc://localhost:5901
      // (If this client has a `Host sodium` ssh_config block, just: ssh -L 5901:127.0.0.1:5900 sodium)
      // High Performance screen sharing can't traverse grand-central -- it needs native UDP 5900-5902.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJKRpVN+BI0l+wj28mUVq3ldRBZUgbsa9CymdCtXF7Vs grand-central yuto.nishida@magnesium-hydroxide",
    ],
  ),

  // Continuously asserts qbittorrent's egress is the VPN exit (not the home IP) and exercises a real
  // ipleak.net torrent magnet; crashloops on a detected leak.
  gluetunLeakTest: gluetunLeakTest.new(),

  cilium: charts.cilium,

  traefikConfig: traefik.reconfigForCilium(),
}