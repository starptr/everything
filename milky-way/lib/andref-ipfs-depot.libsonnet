local utils = import 'milky-way/lib/utils.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// andref-ipfs-depot: a Discord-gated file uploader for the pinned-only kubo node (lib/kubo.libsonnet).
//
// One whale-built Rust binary runs BOTH a serenity Discord bot and an axum HTTP server in one
// process (see andref-ipfs-depot/). A guild member runs `/upload`; the bot replies (ephemerally)
// with a single-use https://<publicHostname>/u/<token> link; the page POSTs the file back; the
// backend pins it to kubo via the RPC `/api/v0/add?pin=true&cid-version=1` (holding a bearer token
// kubo's API.Authorizations scopes to just `/api/v0/add` -- see kubo.libsonnet's depotRpcToken) and
// returns the direct subdomain-gateway link https://<cid>.<gatewayBaseDomain>, which the bot also
// posts back into the channel (a bare URL, so Discord auto-embeds images/video/etc.).
//
// Single process by design: the token-issuing bot and the token-validating HTTP handler share an
// in-memory token store, so they MUST be one process (a separate-services split would need a
// networked store). Hence replicas:1 + Recreate -- a second pod would hold a different store and a
// link issued by one would 403 on the other. The store is disposable (lost on restart; a member
// just re-runs `/upload`), so no PVC.
//
// Exposure: the bot is outbound-only (no ingress); the HTTP server is PUBLIC internet (members open
// the link from anywhere), so it gets a Traefik ingress + a cert-manager TLS cert (DNS-01, same
// pattern as kubo's gateway). The kubo RPC is reached in-cluster via kuboRpcBase (ClusterIP).
{
  new(
    discordBotToken,                       // required -> Secret env DISCORD_BOT_TOKEN
    discordGuildId,                        // required -> Secret env DISCORD_GUILD_ID (guild /upload is registered in)
    kuboRpcToken,                          // required -> Secret env KUBO_RPC_TOKEN (kubo 'depot' grant, scoped to /api/v0/add)
    kuboRpcBase,                           // required -> KUBO_RPC_BASE, e.g. http://kubo.default.svc.cluster.local:5001
    publicHostname,                        // required, NO default -> public host (e.g. depot.andref.app); cert SAN + Ingress host
    issuerName,                            // required, NO default -> cert-manager ClusterIssuer the TLS cert is issued from
    gatewayBaseDomain='ipfs.andref.app',   // -> GATEWAY_BASE_DOMAIN; result links are https://<cid>.<this> (kubo's subdomain gateway)
    name='andref-ipfs-depot',
    namespace='default',
    image=images['andref-ipfs-depot'].fullyQualifiedImageReferencePinned,
    port=8080,                             // HTTP listen port (matches the whale image's ExposedPorts)
  ):: {
    local this = self,
    // The app builds upload links as <APP_BASE_URL>/u/<token>; it is reached over https via Traefik.
    local appBaseUrl = 'https://' + publicHostname,

    // Bot token + guild id + the scoped kubo RPC token, supplied by the caller from sops. stringData
    // lets Kubernetes base64-encode them; the container reads them via envFrom.
    secret: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: name + '-secrets', namespace: namespace },
      type: 'Opaque',
      stringData: {
        DISCORD_BOT_TOKEN: discordBotToken,
        DISCORD_GUILD_ID: std.toString(discordGuildId),
        KUBO_RPC_TOKEN: kuboRpcToken,
      },
    },

    deployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: { name: name, namespace: namespace },
      spec: {
        replicas: 1,
        strategy: { type: 'Recreate' },   // single in-memory token store -- never run two pods at once
        selector: { matchLabels: { app: name } },
        template: {
          metadata: { labels: {} + this.deployment.spec.selector.matchLabels },
          spec: {
            tolerations: [
              { key: 'ephemeral', operator: 'Exists', effect: 'NoSchedule' },
            ],
            containers: [
              {
                name: name,
                image: image,
                env: [
                  { name: 'KUBO_RPC_BASE', value: kuboRpcBase },
                  { name: 'GATEWAY_BASE_DOMAIN', value: gatewayBaseDomain },
                  { name: 'APP_BASE_URL', value: appBaseUrl },
                  { name: 'BIND_ADDR', value: '0.0.0.0:' + std.toString(port) },
                ],
                envFrom: [{ secretRef: { name: this.secret.metadata.name } }],  // discord + kubo tokens
                ports: [{ name: 'http', containerPort: port }],
                readinessProbe: {
                  httpGet: { path: '/healthz', port: 'http' },
                  initialDelaySeconds: 5,
                  periodSeconds: 15,
                },
                livenessProbe: {
                  httpGet: { path: '/healthz', port: 'http' },
                  periodSeconds: 30,
                },
                resources: {
                  requests: { memory: '32Mi', cpu: '10m' },
                  limits: { memory: '256Mi', cpu: '1' },
                },
              },
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
          name: 'http',
          port: port,
          targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[0].ports[0].name, 'http'),
        }],
        type: 'ClusterIP',
      },
    },

    // Public TLS: cert-manager issues a cert for publicHostname into <name>-tls (DNS-01 -- no inbound
    // reachability needed), which Traefik serves. Mirrors lib/kubo.libsonnet's gateway certificate.
    certificate: {
      apiVersion: 'cert-manager.io/v1',
      kind: 'Certificate',
      metadata: { name: name + '-tls', namespace: namespace },
      spec: {
        secretName: name + '-tls',
        dnsNames: [publicHostname],
        issuerRef: { name: issuerName, kind: 'ClusterIssuer' },
      },
    },

    // PUBLIC internet ingress: Discord members open the upload link from anywhere, so this is a
    // Traefik (not tailnet) ingress on the websecure entrypoint, terminating TLS with the cert above
    // and proxying to the ClusterIP Service. The DNS record for publicHostname lives in eight/.
    ingress: {
      apiVersion: 'networking.k8s.io/v1',
      kind: 'Ingress',
      metadata: {
        name: name,
        namespace: namespace,
        annotations: { 'traefik.ingress.kubernetes.io/router.entrypoints': 'websecure' },
      },
      spec: {
        ingressClassName: 'traefik',
        tls: [{
          hosts: [publicHostname],
          secretName: utils.assertEqualAndReturn(this.certificate.spec.secretName, name + '-tls'),
        }],
        rules: [{
          host: publicHostname,
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
