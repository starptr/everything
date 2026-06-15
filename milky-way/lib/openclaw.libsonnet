local utils = import 'milky-way/lib/utils.libsonnet';
local kataRuntimeClass = import 'milky-way/lib/kata-runtime-class.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// OpenClaw AI agent gateway. We draw on OpenClaw's official k8s manifests
// (https://docs.openclaw.ai/install/kubernetes) but follow this repo's convention instead of
// using them directly: a single new() that returns all the manifests as fields.
//
// One deliberate departure from the upstream sample:
//   * gateway.bind = "lan" (listen on 0.0.0.0). Upstream uses "loopback", which only works via
//     `kubectl port-forward`; a Service/Ingress cannot reach a loopback-bound gateway.
//
// Config delivery follows upstream: an init container seeds openclaw.json + workspace/AGENTS.md from
// the ConfigMap into the writable PVC, so OpenClaw -- which rewrites openclaw.json frequently at
// runtime -- isn't blocked by a read-only mount. The seed is only-if-empty so runtime edits persist
// across restarts (and it overwrites the empty mount-point placeholder left by the prior read-only
// subPath setup). All of ~/.openclaw (config + state, e.g. workspace/) is writable on the PVC.
{
  new(
    gatewayToken,                       // -> ${OPENCLAW_GATEWAY_TOKEN}, interpolated by the config
    geminiApiKey,                       // -> GEMINI_API_KEY (the google/* provider)
    name='openclaw',
    namespace='openclaw',               // OPENCLAW_NAMESPACE equivalent
    image=images.openclaw.fullyQualifiedImageReferenceTagged,
    port=18789,
    model='google/gemini-3-flash-preview',
    tailscaleHostname,                  // required, unique tailnet-wide -> https://<tailscaleHostname>.<tailnet>.ts.net
    tailnet=null,                       // tailnet name (e.g. 'tail4c9a'); when set, the control UI
                                        // origin https://<tailscaleHostname>.<tailnet>.ts.net is allowed
    storageClassName='my-custom-zfs-generic-iscsi',
    storageSize='10Gi',
    initImage=images.busybox.fullyQualifiedImageReferenceTaggedForOpenclaw,
    debugIdle=false,                    // when true: replace the gateway with a no-op idle command and
                                        // drop the probes so the pod stays up WITHOUT running the gateway.
                                        // Lets you `kubectl exec` in to repair ~/.openclaw (e.g. a bad
                                        // runtime-written openclaw.json) without a crashloop. Set back to
                                        // false and re-apply to resume normal operation.
  ):: {
    local this = self,
    local configDir = '/home/node/.openclaw',     // HOME=/home/node, image runs as uid 1000
    // bind=lan requires gateway.controlUi.allowedOrigins (OpenClaw v2026.2.26+). Allow the
    // tailnet hostname (when known) plus the loopback origins used via `kubectl port-forward`.
    local controlUiAllowedOrigins =
      (if tailnet != null then ['https://%s.%s.ts.net' % [tailscaleHostname, tailnet]] else [])
      + ['http://localhost:%d' % port, 'http://127.0.0.1:%d' % port],
    local config = {                              // rendered into the ConfigMap as openclaw.json
      gateway: {
        mode: 'local',
        bind: 'lan',                             // 0.0.0.0 -- REQUIRED for Service/Ingress reach
        port: port,
        auth: { mode: 'token', token: '${OPENCLAW_GATEWAY_TOKEN}' },
        controlUi: { enabled: true, allowedOrigins: controlUiAllowedOrigins },
      },
      agents: {
        defaults: { workspace: '~/.openclaw/workspace', model: { primary: model } },
        list: [{ id: 'default', name: 'OpenClaw Assistant', workspace: '~/.openclaw/workspace' }],
      },
      cron: { enabled: false },
    },
    // ConfigMap payload, kept as a local so it both renders the ConfigMap and feeds the
    // pod-template checksum annotation below.
    local configData = {
      'openclaw.json': std.manifestJsonEx(config, '  '),
      'AGENTS.md': '# OpenClaw Assistant\n\nYou are a helpful AI assistant running in Kubernetes.\n',
    },

    namespace_: {
      apiVersion: 'v1',
      kind: 'Namespace',
      metadata: { name: namespace },
    },

    configMap: {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: { name: name + '-config', namespace: namespace },
      data: configData,
    },

    // Mostly plaintext: the gateway token and the Gemini API key are supplied by the caller from
    // sops. stringData lets Kubernetes base64-encode them for us.
    secret: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: name + '-secrets', namespace: namespace },
      type: 'Opaque',
      stringData: {
        OPENCLAW_GATEWAY_TOKEN: gatewayToken,
        GEMINI_API_KEY: geminiApiKey,
      },
    },

    pvc: {
      apiVersion: 'v1',
      kind: 'PersistentVolumeClaim',
      metadata: { name: name + '-home', namespace: namespace },
      spec: {
        accessModes: ['ReadWriteOncePod'],
        storageClassName: storageClassName,
        resources: { requests: { storage: storageSize } },
      },
    },

    deployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: { name: name, namespace: namespace },
      spec: {
        replicas: 1,
        strategy: { type: 'Recreate' },          // RWO PVC: old pod must release before new mounts
        selector: { matchLabels: { app: name } },
        template: {
          metadata: {
            labels: {} + this.deployment.spec.selector.matchLabels,
            // subPath ConfigMap mounts don't live-update, and editing a ConfigMap doesn't roll a
            // Deployment on its own. Hashing the config into the pod template makes a config change
            // alter the template -> `tk apply` rolls the pod and picks up the new files.
            annotations: { 'checksum/config': std.md5(std.manifestJsonEx(configData, '')) },
          },
          spec: {
            runtimeClassName: kataRuntimeClass.name,          // kata microVM isolation
            tolerations: [
              {
                key: 'ephemeral',
                operator: 'Exists',
                effect: 'NoSchedule',
              },
            ],
            securityContext: { fsGroup: 1000, seccompProfile: { type: 'RuntimeDefault' } },
            initContainers: [
              {
                name: 'init-config',
                image: initImage,
                // Upstream pattern: copy the declarative ConfigMap files into the writable PVC so
                // OpenClaw (which rewrites openclaw.json frequently at runtime) isn't blocked by a
                // read-only mount. Seed only when the target is missing/empty (`! -s`): preserves
                // runtime edits across restarts AND overwrites the empty mount-point placeholder left
                // by the previous read-only subPath setup (one-time, automatic migration).
                command: ['sh', '-c', |||
                  set -eu
                  mkdir -p "%(dir)s/workspace"
                  [ -s "%(dir)s/openclaw.json" ] || cp /config/openclaw.json "%(dir)s/openclaw.json"
                  [ -s "%(dir)s/workspace/AGENTS.md" ] || cp /config/AGENTS.md "%(dir)s/workspace/AGENTS.md"
                ||| % { dir: configDir }],
                securityContext: {
                  runAsNonRoot: true,
                  runAsUser: 1000,
                  runAsGroup: 1000,
                  readOnlyRootFilesystem: true,
                  allowPrivilegeEscalation: false,
                  capabilities: { drop: ['ALL'] },
                },
                resources: {
                  requests: { memory: '32Mi', cpu: '50m' },
                  limits: { memory: '64Mi', cpu: '100m' },
                },
                volumeMounts: [
                  { name: 'home', mountPath: configDir },                    // PVC (writable dest)
                  { name: 'config', mountPath: '/config', readOnly: true },  // ConfigMap (seed source)
                ],
              },
            ],
            containers: [
              {
                name: name,
                image: image,
                // debugIdle swaps the gateway for a no-op so the pod stays up for repair (see param).
                command: if debugIdle then ['tail', '-f', '/dev/null'] else ['node', '/app/dist/index.js', 'gateway', 'run'],
                env: [
                  { name: 'HOME', value: '/home/node' },
                  { name: 'OPENCLAW_CONFIG_DIR', value: configDir },
                  { name: 'NODE_ENV', value: 'production' },
                ],
                envFrom: [{ secretRef: { name: this.secret.metadata.name } }],  // token + api key
                ports: [{ name: 'gateway', containerPort: port }],
                securityContext: {
                  runAsNonRoot: true,
                  runAsUser: 1000,
                  readOnlyRootFilesystem: true,
                  allowPrivilegeEscalation: false,
                  capabilities: { drop: ['ALL'] },
                },
                // PVC holds both the seeded config and mutable state -- all writable, so OpenClaw can
                // rewrite openclaw.json at runtime. The ConfigMap is consumed only by the init container.
                volumeMounts: [
                  { name: 'home', mountPath: configDir },
                  { name: 'tmp', mountPath: '/tmp' },
                ],
                // Probes target the gateway, so they're dropped in debugIdle mode (no gateway running).
                [if !debugIdle then 'livenessProbe']: { httpGet: { path: '/healthz', port: 'gateway' }, initialDelaySeconds: 60, periodSeconds: 30 },
                [if !debugIdle then 'readinessProbe']: { httpGet: { path: '/readyz', port: 'gateway' }, initialDelaySeconds: 15, periodSeconds: 10 },
                resources: {
                  requests: { memory: '512Mi', cpu: '250m' },
                  limits: { memory: '2Gi', cpu: '1' },
                },
              },
            ],
            volumes: [
              { name: 'home', persistentVolumeClaim: { claimName: this.pvc.metadata.name } },
              { name: 'config', configMap: { name: this.configMap.metadata.name } },
              { name: 'tmp', emptyDir: {} },
            ],
          },
        },
      },
    },

    service: {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: { name: name, namespace: namespace },
      spec: {
        selector: {} + this.deployment.spec.template.metadata.labels,
        ports: [{
          port: port,
          targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[0].ports[0].name, 'gateway'),
        }],
        type: 'ClusterIP',
      },
    },

    // Tailnet-only L7 ingress (no funnel), mirroring lib/test-tailscale-operator-ingress.libsonnet.
    ingress: {
      apiVersion: 'networking.k8s.io/v1',
      kind: 'Ingress',
      metadata: {
        name: name,
        namespace: namespace,
        annotations: {
          'tailscale.com/funnel': 'false',  // tailnet-only, no public funnel
        },
      },
      spec: {
        ingressClassName: 'tailscale',
        tls: [{ hosts: [tailscaleHostname] }],
        rules: [{
          http: {
            paths: [{
              path: '/',
              pathType: 'Prefix',
              backend: {
                service: {
                  name: this.service.metadata.name,
                  port: { number: utils.assertEqualAndReturn(this.service.spec.ports[0].port, port) },
                },
              },
            }],
          },
        }],
      },
    },
  },
}
