local utils = import 'milky-way/lib/utils.libsonnet';

// Minimal reader for a WireGuard `.conf` (INI format). Jsonnet has no std.parseIni, so we hand-parse
// the one field we need. We extract ONLY [Interface] PrivateKey -- a provider's generated .conf also
// carries a [Peer] block (server PublicKey/Endpoint) and an Address/DNS, but for gluetun's managed
// providers (e.g. protonvpn) gluetun builds the WireGuard config and selects the server itself, so
// those fields are deliberately ignored. The .conf is the single source of truth for just the key.
{
  // privateKeyOf(conf): the base64 WireGuard private key from the `PrivateKey = ...` line.
  // NOTE: split on the FIRST '=' only -- a base64 key ends in '=' padding, so std.split(line, '=')
  // would truncate it; std.splitLimit(line, '=', 1) keeps the padding intact.
  privateKeyOf(conf)::
    local vals = [
      std.stripChars(std.splitLimit(line, '=', 1)[1], ' \t\r')
      for line in std.split(conf, '\n')
      // Comment lines ("# ...") and the [Peer] block never start with PrivateKey, so they're skipped.
      if std.startsWith(std.stripChars(line, ' \t'), 'PrivateKey')
    ];
    utils.assertAndReturn(
      vals,
      function(v) std.length(v) == 1 && std.length(v[0]) > 0,
      'wireguard-conf: expected exactly one non-empty Interface.PrivateKey line in the .conf',
    )[0],
}
