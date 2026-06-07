local utils = import 'milky-way/lib/utils.libsonnet';

// A minimal smoke test for the Tailscale operator's L3 tailnet-exposure path
// (a `ProxyGroup` of type `ingress` + a `Service` of `type: LoadBalancer` with
// `loadBalancerClass: tailscale`). It deploys a single whoami pod, exposes it
// through the proxy group, and lets us confirm the operator advertises the
// backend to the tailnet at a MagicDNS name and forwards raw TCP to the pod.
//
// See https://tailscale.com/docs/kubernetes-operator/ingress/expose-workload-to-tailnet-l3
//
// This deliberately exercises ONLY the L3 LoadBalancer path -- the Service
// itself carries the tailnet exposure via `loadBalancerClass: tailscale` and
// the `tailscale.com/proxy-group` / `tailscale.com/hostname` annotations. There
// is no `Ingress` object and no HTTPS/L7 routing; that L7 path is the separate
// `test-tailscale-operator-ingress.libsonnet` smoke test.
//
// Bringing it up end-to-end is NOT just `tk apply` -- four non-obvious gotchas
// (all verified on methanol/orion-system 2026-06-07; full notes in the
// tailscale-l3-proxygroup-needs-tailnet-approval memory):
//
//  1. Reconciler stalls on ProxyGroup-ready. The operator's service-pg-reconciler
//     logs "ProxyGroup is not (yet) ready" while the ProxyGroup comes up, then
//     goes quiet and does NOT re-fire once it IS ready, leaving the Service
//     unconfigured. Nudge it with a throwaway annotation to force a reconcile:
//       kubectl -n test-k8s annotate svc test-ts-l3 nudge/reconcile=$(date +%s) --overwrite
//
//  2./3. Two SEPARATE tailnet ACL grants are required (this is L3 = a Tailscale
//     Service / VIP, which is gated tailnet-side, not just in-cluster):
//       a. ADVERTISE side -- `autoApprovers.services` for the proxy tag
//          (tag:k8s-orion-system). Without it the operator is stuck at
//          "0/1 proxy backends ready and advertising" and the proxy's
//          `AdvertiseServices` pref stays null.
//       b. ACCESS side -- a `grants` rule naming the service explicitly, e.g.
//          { "src": ["autogroup:member"], "dst": ["svc:test-ts-l3"], "ip": ["80"] }.
//          A blanket `dst:["*"]` grant does NOT cover `svc:` destinations, so
//          "allow everything" is not enough: clients resolve the VIP and see it
//          in their netmap, but TCP to it just times out.
//
//  4. Restart the proxy pod after the svc mapping lands. The ProxyGroup ingress
//     proxy reads /etc/proxies/ingress-config.json (the VIP->ClusterIP mapping)
//     only ONCE at boot; its post-boot config-watch re-checks only the L7
//     serve-config.json, never ingress-config.json. Since the mapping is written
//     only after the Service is advertised (i.e. after boot), the forwarder never
//     picks it up and VIP traffic times out despite everything else being correct.
//     Fix: `kubectl -n tailscale delete pod test-ts-l3-proxies-0` (the StatefulSet
//     recreates it); on reboot it reads the populated config and the VIP is served.
//
// Verify (from a tailnet client with the access grant above):
//   curl http://test-ts-l3.<tailnet>.ts.net/   # returns the whoami echo
{
  new(
    tailscaleHostname='test-ts-l3',  // becomes the tailnet device name; reachable at test-ts-l3.<tailnet>.ts.net
    name='test-ts-l3',
    namespace='test-k8s',
    // whoami echoes the request + headers, making a successful proxy hop self-evident.
    image='traefik/whoami@sha256:200689790a0a0ea48ca45992e0450bc26ccab5307375b41c84dfc4f2475937ab',
    replicas=1,  // ProxyGroup proxy replicas (the doc uses 2; 1 keeps the test light)
  ):: {
    local this = self,

    // The pool of ingress proxies the LoadBalancer Service binds to. ProxyGroup
    // is cluster-scoped, so it carries no namespace. The CRD ships with the
    // vendored operator manifest (lib/tailscale-operator/operator.yaml).
    proxyGroup: {
      apiVersion: 'tailscale.com/v1alpha1',
      kind: 'ProxyGroup',
      metadata: {
        name: name + '-proxies',
      },
      spec: {
        type: 'ingress',
        replicas: replicas,
      },
    },

    deployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: {
        name: name,
        namespace: namespace,
      },
      spec: {
        replicas: 1,
        selector: {
          matchLabels: {
            app: name,
          },
        },
        template: {
          metadata: {
            labels: {} + this.deployment.spec.selector.matchLabels,
          },
          spec: {
            tolerations: [
              {
                key: 'ephemeral',
                operator: 'Exists',
                effect: 'NoSchedule',
              },
            ],
            containers: [{
              name: 'whoami',
              image: image,
              ports: [{
                name: 'main-http',
                containerPort: 80,
              }],
            }],
          },
        },
      },
    },

    service: {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: {
        name: name,
        namespace: namespace,
        annotations: {
          // Bind this LoadBalancer to the proxy group defined above (assert-wired
          // so the name can't drift), and pin the tailnet MagicDNS hostname.
          'tailscale.com/proxy-group': utils.assertEqualAndReturn(this.proxyGroup.metadata.name, name + '-proxies'),
          'tailscale.com/hostname': tailscaleHostname,
        },
      },
      spec: {
        selector: {} + this.deployment.spec.template.metadata.labels,
        ports: [{
          port: 80,
          targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[0].ports[0].name, 'main-http'),
        }],
        type: 'LoadBalancer',
        loadBalancerClass: 'tailscale',
      },
    },
  },
}
