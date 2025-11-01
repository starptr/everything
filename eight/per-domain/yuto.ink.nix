{ configurations-by-file, generated }: {
  "img" = {
    octodns = {
      cloudflare = {
        auto-ttl = true;
      };
    };
    ttl = 300;
    type = "CNAME";
    value = "fractal-cuttlefish.pikapod.net.";
  };
  "public.testpage" = {
    octodns.cloudflare = {
      auto-ttl = true;
      comment = "Test page hosted in milky-way, should be publicly accessible";
    };
    ttl = 60;
    type = "A";
    value = generated.nixie.ipAddress;
  };
  "public-tailscale.testpage" = {
    octodns.cloudflare = {
      auto-ttl = true;
      comment = "Should not work because this record points to the public IP";
    };
    ttl = 60;
    type = "A";
    value = generated.nixie.ipAddress;
  };
  "whoami.testpage" = {
    octodns.cloudflare = {
      auto-ttl = true;
      comment = "Debug whoami page hosted in milky-way, should be publicly accessible";
    };
    ttl = 60;
    type = "A";
    value = generated.nixie.ipAddress;
  };
  "whoami.testpage.sdts" = {
    octodns.cloudflare = {
      auto-ttl = true;
      comment = "Debug whoami page hosted in milky-way, should be publicly accessible";
    };
    ttl = 60;
    type = "A";
    value = "100.112.134.68"; # TODO: use magic / dump `tailscale status`
  };
  "tailscale.testpage" = {
    octodns.cloudflare = {
      auto-ttl = true;
      comment = "Test page hosted in milky-way, should not be accessible without Tailscale";
    };
    ttl = 60;
    type = "A";
    value = "100.112.134.68"; # TODO: use magic / dump `tailscale status`
  };
}