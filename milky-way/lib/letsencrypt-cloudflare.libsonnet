local utils = import 'milky-way/lib/utils.libsonnet';

// Let's Encrypt ClusterIssuers backed by the cert-manager Cloudflare DNS-01 solver, plus the
// Cloudflare API-token Secret they read.
//
// Why cert-manager (not Traefik's built-in ACME): Traefik runs as a hostNetwork DaemonSet on this
// cluster (required for Cilium), so it has one pod per node. Traefik OSS stores ACME state in a local
// acme.json file that cannot be safely shared or issued-against across multiple instances. cert-manager
// instead issues each certificate ONCE (leader-elected) into a Kubernetes Secret that every Traefik pod
// on every node serves via the Ingress's spec.tls.secretName -- correct at any node count.
//
// Returns both a staging and a production ClusterIssuer (cluster-scoped) sharing one Cloudflare
// solver. Callers select which one a Certificate uses via its issuerRef; start on staging and flip to
// prod once the DNS-01 flow is verified (cert-manager then re-issues into the same Secret).
{
  new(
    cloudflareDnsApiToken,                  // required; CF token scoped Zone:DNS:Edit + Zone:Read
    acmeEmail='yuto@berkeley.edu',          // ACME account contact
    namespace='cert-manager',               // a ClusterIssuer resolves its apiTokenSecretRef here
    tokenSecretName='cloudflare-dns-api-token',
    tokenSecretKey='api-token',
    stagingIssuerName='letsencrypt-staging',
    prodIssuerName='letsencrypt-prod',
  ):: {
    local this = self,

    // One Cloudflare DNS-01 solver, reused by both issuers. The secret name/key are read back from the
    // Secret object below and asserted equal, so a rename can't silently break the reference.
    local cloudflareSolver = {
      dns01: {
        cloudflare: {
          apiTokenSecretRef: {
            name: utils.assertEqualAndReturn(tokenSecretName, this.cloudflareTokenSecret.metadata.name),
            key: utils.assertEqualAndReturn(tokenSecretKey, std.objectFields(this.cloudflareTokenSecret.stringData)[0]),
          },
        },
      },
    },

    local clusterIssuer(name, acmeServer) = {
      apiVersion: 'cert-manager.io/v1',
      kind: 'ClusterIssuer',
      metadata: { name: name },
      spec: {
        acme: {
          server: acmeServer,
          email: acmeEmail,
          // Per-issuer ACME account private key (cert-manager creates/manages this Secret).
          privateKeySecretRef: { name: name + '-account-key' },
          solvers: [cloudflareSolver],
        },
      },
    },

    cloudflareTokenSecret: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: tokenSecretName, namespace: namespace },
      type: 'Opaque',
      stringData: { [tokenSecretKey]: cloudflareDnsApiToken },
    },

    clusterIssuerStaging: clusterIssuer(stagingIssuerName, 'https://acme-staging-v02.api.letsencrypt.org/directory'),
    clusterIssuerProd: clusterIssuer(prodIssuerName, 'https://acme-v02.api.letsencrypt.org/directory'),
  },
}
