local utils = import 'milky-way/lib/utils.libsonnet';
local gluetun = import 'milky-way/lib/gluetun.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// Headless qbittorrent whose traffic is forced through a VPN by an embedded gluetun sidecar (see
// lib/gluetun.libsonnet). gluetun + qbittorrent share one network namespace (same pod), and
// gluetun's killswitch makes it impossible for qbittorrent to egress except through the tunnel --
// the only thing reachable from outside is the WebUI, exposed via Tailscale L7 ingress.
//
// Inbound peering / seeding: with no inbound path to the BitTorrent listen port, qbittorrent can
// only dial OUT to peers -- so as a seed it serves nobody (swarm leechers can't connect in). To be
// connectable we use a VPN provider that supports NAT-PMP port forwarding (ProtonVPN; NordVPN does
// NOT). gluetun requests a forwarded port and, on each (re)assignment, runs portForwardingUpCommand
// to push that port into qbittorrent's listen_port via the WebUI API. The forwarded port is DYNAMIC,
// so the seeded Session\Port below is just an initial value -- the live listen port follows gluetun.
//
// Storage: config on iSCSI (RWO) -- qbittorrent rewrites qBittorrent.conf at runtime, so it's
// seeded once (only-if-empty) into the PVC. Downloads live on a SHARED volume (the external
// `mdata` RWX-NFS PVC, mounted at /data) under downloads/qbittorrent/ -- other apps mount the same
// volume and hardlink between subdirs (hardlinks require one filesystem), so the directory tree is not
// owned by qbittorrent here.
{
  new(
    wireguardPrivateKey,                // positional, required -> gluetun (ProtonVPN/WireGuard)
    name='qbittorrent',
    namespace='default',
    image=images.qbittorrent.fullyQualifiedImageReferencePinned,
    webuiPort=8080,
    tailscaleHostname,                  // required, unique tailnet-wide -> https://<tailscaleHostname>.<tailnet>.ts.net
    vpnProvider,                        // required: must support port forwarding for inbound peers (see header)
    serverCountries,                    // required: SERVER_COUNTRIES, e.g. 'United States'
    configStorageClassName='my-custom-zfs-generic-iscsi',     // RWO
    configStorageSize='5Gi',
    volumeClaimName,                    // required -> external shared RWX PVC (defined in main.jsonnet)
    volumeMountPath,                    // required -> whole volume mounted here
    downloadsSubdir,                    // required -> qbittorrent's save dir within the volume
    // Optional "run on torrent finished" -> Sonarr import hook. null disables it. When set, shape is
    // { sonarrHost, sonarrPort, sonarrApiKey, category, importMode? }: on each COMPLETED torrent in `category`,
    // qbittorrent asks Sonarr to do a PATH/file-level import of the content. This exists because
    // Sonarr's queue-based Completed Download Handling resolves the series by parsing the torrent's
    // TOP-LEVEL name, so SeaDex batches whose name lacks a season/episode token (e.g. "Frieren Beyond
    // Journey's End (BD Remux ...)") never import even though the files inside are "... - S01E01 ...".
    // A path scan parses each file instead, so it succeeds. See the hook script comment below.
    onTorrentFinished=null,
    // Optional "run on torrent finished" -> HARDLINK-into-a-directory hook. null disables it. When set,
    // shape is { tags?, categories?, destDir } (at least one selector): on each COMPLETED torrent whose
    // category is in `categories` OR that carries any tag in `tags`, qbittorrent hardlinks the content
    // into `destDir` (a recursive same-fs `cp -al`, so no extra disk and the torrent keeps seeding).
    // This exists for the Shoko workflow -- Shoko organizes anime but CANNOT hardlink itself, so
    // qbittorrent drops a hardlink into Shoko's "drop source" folder and Shoko move-organizes it from
    // there (a same-fs move preserves the inode). `destDir` must be on the SAME shared volume as the
    // downloads (both under /data) for the links to work. See lib/shoko.libsonnet. Prefer a TAG
    // (`on-finish-hardlink-to-shoko-import`) so any producer can opt a torrent in per-item; a category
    // is retained only where a producer can't set a tag -- e.g. sonarr-for-sdxarr, whose Sonarr download
    // client sets no qBittorrent tags. The Shoko handler FALLS THROUGH (doesn't exit), so a torrent that
    // is ALSO in onTorrentFinished's Sonarr-import category gets BOTH: hardlinked into Shoko AND imported
    // by Sonarr. qbittorrent runs a single on-finished program, so this and onTorrentFinished share one
    // dispatching script (below) that branches on category/tags; either or both may be set.
    hardlinkOnFinished=null,
    initImage=images.busybox.fullyQualifiedImageReferenceTaggedForQbittorrent,
  ):: {
    local this = self,
    local controlPort = 8000,           // gluetun control server (publicip route)
    local downloadsPath = volumeMountPath + '/' + downloadsSubdir,   // /data/downloads/qbittorrent

    // Cluster CIDRs (k3s defaults; verified on methanol). Used for the killswitch allowlist AND the
    // qbittorrent reverse-proxy / auth-subnet whitelist below.
    local podCidr = '10.42.0.0/16',
    local svcCidr = '10.43.0.0/16',
    // kube-dns ClusterIP (k3s puts it at .10 of the service CIDR; verified on methanol). The
    // on-torrent-finished hook needs it because this pod's ONLY resolver is gluetun's 127.0.0.1
    // (public DNS over the tunnel), which cannot resolve in-cluster Service names -- so the hook
    // resolves Sonarr through kube-dns explicitly and dials the returned IP (gluetun's killswitch
    // already allows svcCidr outbound).
    local clusterDnsIp = '10.43.0.10',

    // Commands gluetun runs when the forwarded port comes up / goes down: set qbittorrent's
    // listen_port to gluetun's {{PORT}} via the WebUI API. They run inside the gluetun container,
    // which shares qbittorrent's netns, so 127.0.0.1:webui reaches qbittorrent; and 127.0.0.0/8 is
    // in AuthSubnetWhitelist below, so the API call needs no credentials. gluetun's image ships
    // /bin/sh + wget. `sq` is a backslash-escaped double-quote: the JSON body must stay double-quoted
    // for `sh -c` (the {..,..} would otherwise trigger brace expansion / word splitting).
    local sq = '\\"',
    local setPrefsUrl = 'http://127.0.0.1:%d/api/v2/app/setPreferences' % webuiPort,
    local upBody = 'json={' + sq + 'listen_port' + sq + ':{{PORT}},'
                   + sq + 'random_port' + sq + ':false,' + sq + 'upnp' + sq + ':false}',
    local downBody = 'json={' + sq + 'listen_port' + sq + ':0}',
    local pfUpCommand = "/bin/sh -c 'wget -O- -nv --retry-connrefused --post-data \""
                        + upBody + "\" " + setPrefsUrl + "'",
    local pfDownCommand = "/bin/sh -c 'wget -O- -nv --retry-connrefused --post-data \""
                          + downBody + "\" " + setPrefsUrl + "'",

    // The VPN sidecar fragments, embedded into this pod below.
    vpn:: gluetun.new(
      wireguardPrivateKey=wireguardPrivateKey,
      name=name + '-gluetun',
      namespace=namespace,
      vpnProvider=vpnProvider,
      vpnType='wireguard',
      serverCountries=serverCountries,
      controlPort=controlPort,
      firewallOutboundSubnets='%s,%s' % [podCidr, svcCidr],
      firewallInputPorts=[webuiPort, controlPort],
      portForwarding=true,
      portForwardingUpCommand=pfUpCommand,
      portForwardingDownCommand=pfDownCommand,
    ),

    // Seed qBittorrent.conf. WebUI keys make the WebUI work behind the Tailscale proxy:
    //   * HostHeaderValidation/CSRF/Clickjacking off + ReverseProxySupport + TrustedReverseProxies:
    //     the proxy forwards Host: <hostname>.<tailnet>.ts.net from a pod-CIDR source, which
    //     qbittorrent would otherwise reject.
    //   * AuthSubnetWhitelist (pod+service CIDRs) bypasses login for in-cluster callers -- this also
    //     covers the Tailscale operator proxy pod, so the tailnet itself is the auth boundary (same
    //     model as openclaw) and the leak-test needs no credentials.
    local qbtConfInitialSeed = std.join('\n', [
      '[Application]',
      'FileLogger\\Enabled=true',
      '',
      '[BitTorrent]',
      'Session\\DefaultSavePath=%s' % downloadsPath,
      'Session\\Port=6881',   // initial only -- gluetun's portForwardingUpCommand overwrites this at runtime

      '',
      '[Preferences]',
      'WebUI\\Address=*',
      'WebUI\\Port=%d' % webuiPort,
      'WebUI\\HostHeaderValidation=false',
      'WebUI\\CSRFProtection=false',
      'WebUI\\ClickjackingProtection=false',
      'WebUI\\ReverseProxySupportEnabled=true',
      'WebUI\\TrustedReverseProxiesList=%s,%s' % [podCidr, svcCidr],
      'WebUI\\AuthSubnetWhitelistEnabled=true',
      'WebUI\\AuthSubnetWhitelist=%s, %s, 127.0.0.0/8' % [podCidr, svcCidr],
      'WebUI\\LocalHostAuth=false',
      'WebUI\\Username=admin',
      '',
    ]),
    local configDataInitialSeed = { 'qBittorrent.conf': qbtConfInitialSeed },

    // ---- Optional "run on torrent finished" -> Sonarr import hook (see the onTorrentFinished param) ----
    local hookEnabled = onTorrentFinished != null || hardlinkOnFinished != null,
    local hookImportMode =
      if onTorrentFinished != null && std.objectHas(onTorrentFinished, 'importMode')
      then onTorrentFinished.importMode
      else 'Copy',   // "Copy" = copy-or-HARDLINK (honors Sonarr's "use hardlinks"); never "Move" (breaks seeding)

    // The program qbittorrent runs on completion. It substitutes its own tokens into the argv:
    // %F = content path, %L = category, %G = tags (quoted so values with spaces survive). We keep the
    // actual logic in a mounted script (below) rather than an inline command so quoting stays sane. The
    // script dispatches on category and tags, so the two handlers (Sonarr import, Shoko hardlink) coexist.
    local autorunProgram = '/bin/sh /scripts/on-complete.sh "%F" "%L" "%G"',
    // Common preamble: shebang + param parse. Each handler below is appended only when its feature is
    // configured, so a single-feature hook renders exactly that feature's logic (and nothing else).
    local autorunScriptPreamble = |||
      #!/bin/sh
      # qbittorrent "run on torrent finished" hook. qbittorrent substitutes its parameters into the
      # argv: $1 = %F (content path), $2 = %L (category), $3 = %G (comma-separated tags). It fires once
      # per COMPLETED torrent, so $1 is always fully-downloaded content -- no partial-file risk. The
      # handlers below dispatch on the torrent's category ($2) and/or its tags ($3), ignoring the rest.
      set -eu
      content_path=${1:-}
      category=${2:-}
      tags=${3:-}
    |||,
    // Shoko hardlink handler (appended only when hardlinkOnFinished is set).
    local autorunScriptShoko = |||
      # Shoko drop-source handler: hardlink the finished content into Shoko's drop-source folder when the
      # torrent matches a configured drop selector -- its category is in $SHOKO_DROP_CATEGORIES OR one of
      # its tags is in $SHOKO_DROP_TAGS -- then let Shoko rename-and-move-organize it into its library.
      # The drop source and the library sit on one filesystem, so Shoko's move is an inode-preserving
      # rename -- the torrent keeps seeding from downloads/qbittorrent/ while an organized hardlink lands
      # in the library, one physical copy. (Shoko cannot create the link itself, so qbittorrent does it
      # here.) cp -al = recursive same-fs hardlink. Prefer the TAG selector so any producer can opt a
      # torrent in per-item; the category selector is retained only for producers that can't set a tag
      # (sonarr-for-sdxarr's Sonarr download client). This branch FALLS THROUGH (no exit): a torrent that
      # is ALSO in the Sonarr-import category (sonarr-for-sdxarr) then reaches the Sonarr handler below and
      # gets imported into the *arr library too. The `[ -e ]` guard keeps a re-fire idempotent while the
      # link still sits in the drop source (a re-fire AFTER Shoko moves it out could re-introduce a copy,
      # which Shoko's Release Management then flags -- acceptable here). The link is best-effort (`|| :`)
      # so a hardlink failure can't abort before the Sonarr import under `set -e`.
      matched=0
      if [ -n "${SHOKO_DROP_CATEGORIES:-}" ]; then
        case " $SHOKO_DROP_CATEGORIES " in *" $category "*) matched=1 ;; esac
      fi
      if [ -n "${SHOKO_DROP_TAGS:-}" ]; then
        # %G joins tags with "," or ", " depending on qbittorrent version; tag names contain no comma, so
        # normalize ", "->"," and comma-wrap for an unambiguous membership test. $SHOKO_DROP_TAGS is
        # space-split, so configured tag names must be space-free (on-finish-hardlink-to-shoko-import is).
        tags_csv=$(printf '%s' "$tags" | sed 's/, /,/g')
        for want in $SHOKO_DROP_TAGS; do
          case ",$tags_csv," in *",$want,"*) matched=1 ;; esac
        done
      fi
      if [ "$matched" = 1 ] && [ -n "$content_path" ]; then
        mkdir -p "$SHOKO_DROP_DIR"
        dest="$SHOKO_DROP_DIR/$(basename "$content_path")"
        [ -e "$dest" ] || cp -al "$content_path" "$SHOKO_DROP_DIR/" || :
      fi
    |||,
    // Sonarr import handler (appended only when onTorrentFinished is set). Guard-based: it exits 0
    // unless the torrent is in this Sonarr instance's category, so it is safe to run after the Shoko
    // branch above.
    local autorunScriptSonarr = |||
      # Why this exists: sonarr-for-sdxarr has no indexers -- SeaDexArr adds torrents straight to
      # qbittorrent and Sonarr imports them via Completed Download Handling, which resolves the
      # series by parsing the torrent's TOP-LEVEL name. SeaDex "best" batches whose name lacks a
      # season/episode token (e.g. "Frieren Beyond Journey's End (BD Remux ...)") fail that parse and
      # never import, even though the files inside are named "... - S01E01 ...". Sonarr's
      # /manualimport endpoint parses each FILE (not the folder name), so it resolves the series
      # per-file and imports what the queue/folder scan can't. (A DownloadedEpisodesScan command does
      # NOT work here -- it parses the folder name too and gives up "Unknown Series".)
      # Only this Sonarr instance's category; ignore anything else (e.g. legacy tv-sonarr grabs).
      [ "$category" = "$SONARR_IMPORT_CATEGORY" ] || exit 0
      [ -n "$content_path" ] || exit 0
      # This pod's only resolver is gluetun's 127.0.0.1 (public DNS over the tunnel), so it can't
      # resolve the in-cluster Sonarr Service name. Resolve it via kube-dns explicitly, then dial the
      # returned IP with --resolve (gluetun already allows svcCidr outbound; Host stays the name).
      sonarr_ip=$(nslookup "$SONARR_HOST" "$CLUSTER_DNS_IP" 2>/dev/null | awk '/^Name:/{seen=1} seen&&/^Address/{print $NF; exit}')
      [ -n "$sonarr_ip" ] || { echo "on-complete: could not resolve $SONARR_HOST via $CLUSTER_DNS_IP" >&2; exit 1; }
      api="http://$SONARR_HOST:$SONARR_PORT"
      # 1. Ask Sonarr to parse each file in the folder (it returns a per-file series/episode match +
      #    a rejections list). filterExistingFiles is a cheap first pass; the real dedup is step 2.
      candidates=$(curl -fsS -m 300 --resolve "$SONARR_HOST:$SONARR_PORT:$sonarr_ip" -G "$api/api/v3/manualimport" \
        -H "X-Api-Key: $SONARR_API_KEY" \
        --data-urlencode "folder=$content_path" \
        --data-urlencode "filterExistingFiles=true")
      # 2. Keep only files Sonarr matched to a series + episode(s), with no rejections, AND whose
      #    episode(s) do NOT already have a file. That last guard is load-bearing: manual import
      #    otherwise force-REPLACES existing files (its rejection list doesn't stop it), which would
      #    both make the hook non-idempotent (re-fire re-imports everything) and, worse, clobber a
      #    prior release under this instance's upgradeAllowed=false / first-grab-wins policy (e.g.
      #    overwrite an already-imported DVD version with a later batch). It also drops extras
      #    (NCED/NCOP/...) since those match no episode.
      files=$(printf '%s' "$candidates" | jq -c '[.[] | select(.series != null and (.episodes | length > 0) and (.rejections | length == 0) and (any(.episodes[]; .hasFile) | not)) | {path, seriesId: .series.id, episodeIds: [.episodes[].id], quality, languages, releaseGroup, indexerFlags: (.indexerFlags // 0)}]')
      count=$(printf '%s' "$files" | jq 'length')
      [ "$count" -gt 0 ] || { echo "on-complete: no importable episodes in $content_path"; exit 0; }
      # 3. Import them. importMode "Copy" honors Sonarr's "use hardlinks" setting -> one physical copy
      #    on the shared mdata fs, source kept so the torrent keeps seeding.
      printf '{"name":"ManualImport","importMode":"%s","files":%s}' "$SONARR_IMPORT_MODE" "$files" \
        | curl -fsS -m 300 --resolve "$SONARR_HOST:$SONARR_PORT:$sonarr_ip" -X POST "$api/api/v3/command" \
            -H "X-Api-Key: $SONARR_API_KEY" -H 'Content-Type: application/json' --data @-
    |||,
    local autorunScript =
      autorunScriptPreamble
      + (if hardlinkOnFinished != null then autorunScriptShoko else '')
      + (if onTorrentFinished != null then autorunScriptSonarr else ''),
    local autorunScriptData = { 'on-complete.sh': autorunScript },

    // Enforce the hook via the WebUI API on every start (idempotent). The seeded qBittorrent.conf is
    // only-if-empty and the live PVC config already exists, so a seed change wouldn't take -- instead
    // we set the pref at runtime, the same setPreferences path gluetun's port-forward command uses
    // (127.0.0.1 is in AuthSubnetWhitelist + LocalHostAuth=false, so no creds). autorun_enabled +
    // autorun_program are qbittorrent 5's "run on torrent finished" prefs. std.manifestJsonEx yields
    // the JSON-escaped program string (\"%F\" \"%L\"). strReplace (not %-format) keeps the qbittorrent
    // %F/%L tokens out of jsonnet's formatter.
    local setPrefsLocalUrl = 'http://127.0.0.1:%d/api/v2/app/setPreferences' % webuiPort,
    local setPrefsJson = '{"autorun_enabled":true,"autorun_program":' + std.manifestJsonEx(autorunProgram, '') + '}',
    local hookPostStartCommand = std.strReplace(std.strReplace(|||
      # Retry until the WebUI answers, then exit 0 unconditionally so a transient failure to set the
      # pref never crashes the container.
      i=0
      while [ "$i" -lt 60 ]; do
        curl -fsS -m 5 -X POST 'SET_PREFS_URL' --data-urlencode 'JSON_BODY' && exit 0
        i=$((i + 1))
        sleep 2
      done
      exit 0
    |||, 'SET_PREFS_URL', setPrefsLocalUrl), 'JSON_BODY', 'json=' + setPrefsJson),

    // Container/volume fragments spliced into the pod below only when the hook is enabled.
    local hookEnv =
      (if onTorrentFinished != null then [
        { name: 'SONARR_HOST', value: onTorrentFinished.sonarrHost },
        { name: 'SONARR_PORT', value: std.toString(onTorrentFinished.sonarrPort) },
        { name: 'CLUSTER_DNS_IP', value: clusterDnsIp },
        { name: 'SONARR_IMPORT_CATEGORY', value: onTorrentFinished.category },
        { name: 'SONARR_IMPORT_MODE', value: hookImportMode },
        // Keep the key out of the Deployment's plaintext env -- pull it from a Secret this lib renders.
        { name: 'SONARR_API_KEY', valueFrom: { secretKeyRef: { name: name + '-sonarr-import', key: 'sonarr-api-key' } } },
      ] else [])
      + (if hardlinkOnFinished != null then
           (if std.objectHas(hardlinkOnFinished, 'categories')
            then [{ name: 'SHOKO_DROP_CATEGORIES', value: std.join(' ', hardlinkOnFinished.categories) }] else [])
           + (if std.objectHas(hardlinkOnFinished, 'tags')
              then [{ name: 'SHOKO_DROP_TAGS', value: std.join(' ', hardlinkOnFinished.tags) }] else [])
           + [{ name: 'SHOKO_DROP_DIR', value: hardlinkOnFinished.destDir }]
         else []),
    local hookVolumeMounts = if hookEnabled then [{ name: 'autorun-scripts', mountPath: '/scripts', readOnly: true }] else [],
    local hookVolumes = if hookEnabled then [{ name: 'autorun-scripts', configMap: { name: name + '-autorun' } }] else [],
    local hookLifecycle = if hookEnabled then { lifecycle: { postStart: { exec: { command: ['/bin/sh', '-c', hookPostStartCommand] } } } } else {},
    // Fold the hook data into the pod-template checksum so editing the script/program rolls the pod.
    // When disabled this is byte-identical to the old input, so existing deployments don't churn.
    local podTemplateChecksumInput =
      std.manifestJsonEx(configDataInitialSeed, '')
      + (if hookEnabled then '\n' + std.manifestJsonEx(autorunScriptData, '') + '\n' + autorunProgram else ''),

    // Re-emit the gluetun-owned manifests so Tanka applies them.
    vpnSecret: this.vpn.secret,
    vpnControlConfig: this.vpn.configMap,

    // Hook resources (only when enabled): the script ConfigMap (for either handler) and the
    // Sonarr-API-key Secret (only when the Sonarr handler is used). NB: computed field KEYS are
    // evaluated in the enclosing scope, so they can see the `onTorrentFinished`/`hardlinkOnFinished`
    // params but NOT the object-local `hookEnabled` -- gate on the params directly.
    [if onTorrentFinished != null || hardlinkOnFinished != null then 'autorunConfigMap']: {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: { name: name + '-autorun', namespace: namespace },
      data: autorunScriptData,
    },
    [if onTorrentFinished != null then 'sonarrImportSecret']: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: { name: name + '-sonarr-import', namespace: namespace },
      stringData: { 'sonarr-api-key': onTorrentFinished.sonarrApiKey },
    },

    configMapInitialSeed: {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: { name: name + '-config', namespace: namespace },
      data: configDataInitialSeed,
    },

    configPvc: {
      apiVersion: 'v1',
      kind: 'PersistentVolumeClaim',
      metadata: { name: name + '-config', namespace: namespace },
      spec: {
        accessModes: ['ReadWriteOncePod'],
        storageClassName: configStorageClassName,
        resources: { requests: { storage: configStorageSize } },
      },
    },

    deployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: { name: name, namespace: namespace },
      spec: {
        replicas: 1,
        strategy: { type: 'Recreate' },   // RWO config PVC: old pod must release before new mounts
        selector: { matchLabels: { app: name } },
        template: {
          metadata: {
            labels: {} + this.deployment.spec.selector.matchLabels,
            annotations: { 'checksum/config': std.md5(podTemplateChecksumInput) },
          },
          spec: {
            tolerations: [
              { key: 'ephemeral', operator: 'Exists', effect: 'NoSchedule' },
            ],
            // DNS: drop the cluster search domains for this pod. The image is Alpine (musl); musl's
            // getaddrinfo honors the k8s-injected `search` + `options ndots:5` in resolv.conf, so a
            // tracker host like tracker.ipleak.net (2 dots < 5) gets the cluster search domains
            // appended FIRST, the upstream returns authoritative NXDOMAIN for each, and musl fails
            // instead of falling back to the absolute name (glibc would). qbittorrent only resolves
            // PUBLIC hosts (trackers/peers/DHT) via gluetun's 127.0.0.1 resolver and NEVER an
            // in-cluster name (the *arr apps dial INTO it; gluetun's port-forward command uses
            // literal 127.0.0.1), so the cluster search domains are pure dead weight here and the
            // sole cause of "Host not found (authoritative)" on every tracker. dnsPolicy:None drops
            // them entirely -- no suffix is ever appended, so every tracker name resolves as-is.
            // dnsPolicy:None REQUIRES a nameserver, so we declare gluetun's embedded resolver
            // (127.0.0.1) -- which gluetun rewrites resolv.conf to anyway, so this just matches
            // reality. gluetun's own startup is unaffected: it reaches the VPN via IPs from its
            // embedded server list and runs its own resolver, not the pod's kubelet DNS.
            dnsPolicy: 'None',
            dnsConfig: {
              nameservers: ['127.0.0.1'],
              searches: [],
            },
            // No pod-level sysctls: gluetun sets WireGuard's src_valid_mark itself inside its netns
            // (see lib/gluetun.libsonnet) -- a pod securityContext.sysctls entry would be rejected
            // with SysctlForbidden.
            initContainers: [
              {
                // Seed qBittorrent.conf only when missing/empty so qbittorrent's runtime rewrites of
                // the file persist across restarts (mirrors openclaw's init-config seed pattern).
                name: 'init-config',
                image: initImage,
                // Seed the config (only-if-empty) AND ensure the save dir exists and is writable by
                // the qbittorrent uid (1000) on the shared volume. The NFS export root-squashes,
                // so chown(1000) from this root container is EPERM; instead chmod the leaf 0777 (the
                // creating owner may chmod), matching the driver's 0777 volume-root convention. The
                // parents stay 0755/traversable.
                command: ['sh', '-c',
                  ((|||
                    set -eu
                    mkdir -p /config/qBittorrent
                    [ -s /config/qBittorrent/qBittorrent.conf ] \
                      || cp /seed/qBittorrent.conf /config/qBittorrent/qBittorrent.conf
                    mkdir -p %(dl)s
                    chmod 0777 %(dl)s
                  |||) % { dl: downloadsPath })
                  + (if hardlinkOnFinished != null then
                       // Shoko's drop-source lives under the nobody-owned /data/downloads, so this
                       // root init (root->nobody on the squashed NFS) must create it and chmod 0777 --
                       // matching %(dl)s above -- so the uid-1000 qbittorrent hook AND uid-1000 Shoko
                       // can both write it.
                       ('mkdir -p "%(sd)s"\nchmod 0777 "%(sd)s"\n' % { sd: hardlinkOnFinished.destDir })
                     else '')],
                volumeMounts: [
                  { name: 'config', mountPath: '/config' },
                  { name: 'config-seed', mountPath: '/seed', readOnly: true },
                  { name: 'volume', mountPath: volumeMountPath },
                ],
                resources: {
                  requests: { memory: '16Mi', cpu: '25m' },
                  limits: { memory: '32Mi', cpu: '50m' },
                },
              },
            ],
            // gluetun FIRST (tunnel + killswitch up before the app egresses), then qbittorrent, which
            // shares gluetun's netns automatically (same pod) -- no netns/cap settings of its own.
            containers: this.vpn.containers + [
              {
                name: name,
                image: image,
                env: [
                  { name: 'PUID', value: '1000' },
                  { name: 'PGID', value: '1000' },
                  { name: 'TZ', value: 'America/Los_Angeles' },
                  { name: 'WEBUI_PORT', value: std.toString(webuiPort) },
                ] + hookEnv,
                ports: [{ name: 'webui', containerPort: webuiPort }],
                volumeMounts: [
                  { name: 'config', mountPath: '/config' },
                  { name: 'volume', mountPath: volumeMountPath },
                ] + hookVolumeMounts,
                readinessProbe: {
                  httpGet: { path: '/', port: 'webui' },
                  initialDelaySeconds: 20,
                  periodSeconds: 15,
                },
                resources: {
                  requests: { memory: '256Mi', cpu: '100m' },
                  limits: { memory: '2Gi', cpu: '1' },
                },
              } + hookLifecycle,
            ],
            volumes: this.vpn.volumes + [
              { name: 'config', persistentVolumeClaim: { claimName: this.configPvc.metadata.name } },
              { name: 'volume', persistentVolumeClaim: { claimName: volumeClaimName } },
              { name: 'config-seed', configMap: { name: this.configMapInitialSeed.metadata.name } },
            ] + hookVolumes,
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
        ports: [
          {
            name: 'webui',
            port: webuiPort,
            // qbittorrent is the 2nd container (gluetun is [0]); assert its port is named 'webui'.
            targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[1].ports[0].name, 'webui'),
          },
          {
            // gluetun's control port, exposed so the leak-test can read the VPN exit IP via Service DNS.
            name: 'gluetun-ctrl',
            port: controlPort,
            targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[0].ports[0].name, 'gluetun-ctrl'),
          },
        ],
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
        annotations: { 'tailscale.com/funnel': 'false' },
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
                  port: { number: utils.assertEqualAndReturn(this.service.spec.ports[0].port, webuiPort) },
                },
              },
            }],
          },
        }],
      },
    },
  },
}
