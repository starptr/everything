local images = import 'milky-way/lib/images.libsonnet';

// yutobot-discord: Yuto's personal Discord bot, migrated off its old CapRover droplet.
//
// One whale-built Node process (discord.js v12) that logs into Discord and reacts to guild events:
// canvas-rendered welcome/wii-menu cards, an owoifier, and simple call/response commands (see
// yutobot-discord/). It is OUTBOUND-ONLY -- it opens a gateway websocket to Discord and runs no
// inbound server -- so there is NO Service/Ingress/Certificate here, only a Secret + Deployment.
//
// Config: the app calls dotenv.config(), which reads ./.env from the process CWD. The whale image
// sets WorkingDir=/app, and this lib mounts the whole sops-managed .env (passed in as
// envFileContent -- one opaque Secret value) at /app/.env. Every DISCORD_* var lives in that file;
// nothing bot-specific is set as discrete env here (the image sets only TZ/SSL_CERT_FILE).
//
// Singleton: replicas 1 + Recreate. Two pods would each hold a live bot session and double-handle
// every Discord event (double welcomes/owoifies); Recreate guarantees the old pod is gone before
// the new one logs in. The bot keeps no persistent state, so there is no PVC.
{
  new(
    envFileContent,                        // required -> the whole decrypted .env (from sops), mounted at /app/.env
    name='yutobot-discord',
    namespace='default',
    image=images['yutobot-discord'].fullyQualifiedImageReferencePinned,
  ):: {
    local this = self,
    // The Secret key that is both stored and mounted; keep the two in lockstep off one local.
    local envFileName = '.env',

    // The entire .env as one opaque Secret value. stringData lets Kubernetes base64-encode it; the
    // container mounts just this key as the file /app/.env (subPath), which dotenv then reads.
    secret: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: name + '-env', namespace: namespace },
      type: 'Opaque',
      stringData: { [envFileName]: envFileContent },
    },

    deployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: { name: name, namespace: namespace },
      spec: {
        replicas: 1,
        strategy: { type: 'Recreate' },   // singleton bot session -- never run two pods at once
        selector: { matchLabels: { app: name } },
        template: {
          metadata: {
            labels: {} + this.deployment.spec.selector.matchLabels,
            // Roll the pod when the .env changes: a subPath Secret mount does not live-update, and
            // editing a Secret doesn't roll a Deployment on its own. Hashing the file into the
            // template makes `tk apply` restart the bot on a token/channel-id change.
            annotations: { 'checksum/env': std.md5(envFileContent) },
          },
          spec: {
            tolerations: [
              { key: 'ephemeral', operator: 'Exists', effect: 'NoSchedule' },
            ],
            containers: [
              {
                name: name,
                image: image,
                // dotenv reads ./.env from CWD; the image's WorkingDir is /app, so mount the single
                // Secret key there. subPath keeps it a lone file instead of shadowing all of /app.
                volumeMounts: [{
                  name: 'env',
                  mountPath: '/app/' + envFileName,
                  subPath: envFileName,
                  readOnly: true,
                }],
                resources: {
                  // Idle footprint on the old droplet was ~80Mi; the only spike is canvas rendering
                  // a 1920x1080 card on demand, so 256Mi is ample headroom.
                  requests: { memory: '64Mi', cpu: '10m' },
                  limits: { memory: '256Mi', cpu: '500m' },
                },
              },
            ],
            volumes: [{
              name: 'env',
              secret: { secretName: this.secret.metadata.name },
            }],
          },
        },
      },
    },
  },
}
