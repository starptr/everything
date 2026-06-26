{ configurations-by-file, generated, handles-to-records, atproto-handles }: {
  "" = [
    {
      octodns.cloudflare = {
        auto-ttl = true;
      };
      ttl = 300;
      type = "A";
      value = generated.serverref.ipAddress;
    }
    {
      octodns.cloudflare = {
        auto-ttl = true;
        comment = "Another mx record with comment";
      };
      ttl = 300;
      type = "MX";
      values = [
        { exchange = "eforward1.registrar-servers.com."; preference = 10; }
        { exchange = "eforward2.registrar-servers.com."; preference = 10; }
        { exchange = "eforward3.registrar-servers.com."; preference = 10; }
        { exchange = "eforward4.registrar-servers.com."; preference = 15; }
        { exchange = "eforward5.registrar-servers.com."; preference = 20; }
      ];
    }
    {
      octodns.cloudflare = {
        auto-ttl = true;
      };
      ttl = 300;
      type = "TXT";
      value = "v=spf1 include:spf.efwd.registrar-servers.com ~all";
    }
  ];

  "_minecraft._tcp.mc" = {
    octodns.cloudflare = {
      auto-ttl = true;
      comment = "For pebblehost west-2";
    };
    ttl = 300;
    type = "SRV";
    value = {
      port = 25590;
      priority = 5;
      target = "mc.andref.app.";
      weight = 0;
    };
  };

  "_minecraft._udp.mc" = {
    octodns.cloudflare = {
      auto-ttl = true;
      comment = "For pebblehost west-2, bedrock";
    };
    ttl = 300;
    type = "SRV";
    value = {
      port = 25590;
      priority = 0;
      target = "mc.andref.app.";
      weight = 5;
    };
  };

  mc = {
    octodns.cloudflare = { auto-ttl = true; };
    ttl = 300;
    type = "A";
    value = "51.222.147.236";
  };

  # Wildcard + apex for the Traefik / cert-manager Let's Encrypt DNS-01 smoke test
  # (milky-way orion-system). Both CNAME to the home-IP DDNS target (same pattern as
  # grand-central) so a wildcard cert can be obtained and served by Traefik on methanol.
  # DNS-only (grey cloud); the /-ddns$/ rejectlist does not match these labels.
  "test-traefik-acme" = {
    octodns.cloudflare = { auto-ttl = true; };
    ttl = 300;
    type = "CNAME";
    value = "carless-drivers-ddns.andref.app.";
  };

  "*.test-traefik-acme" = {
    octodns.cloudflare = { auto-ttl = true; };
    ttl = 300;
    type = "CNAME";
    value = "carless-drivers-ddns.andref.app.";
  };

  # Public subdomain IPFS gateway (kubo, milky-way orion-system). CNAME to the home-IP DDNS
  # target (same pattern as grand-central / test-traefik-acme) so Traefik on methanol serves it
  # with a cert-manager wildcard cert. DNS-only (grey cloud); the /-ddns$/ rejectlist does not
  # match these labels. Content is served origin-isolated at <cid>.ipfs.andref.app.
  "ipfs" = {
    octodns.cloudflare = { auto-ttl = true; };
    ttl = 300;
    type = "CNAME";
    value = "carless-drivers-ddns.andref.app.";
  };

  "*.ipfs" = {
    octodns.cloudflare = { auto-ttl = true; };
    ttl = 300;
    type = "CNAME";
    value = "carless-drivers-ddns.andref.app.";
  };

  old = {
    octodns.cloudflare = { auto-ttl = true; };
    ttl = 300;
    type = "A";
    value = "137.184.94.125";
  };

  "old.tilde" = {
    octodns.cloudflare = { auto-ttl = true; };
    ttl = 300;
    type = "A";
    value = "137.184.94.125";
  };

  www = {
    octodns.cloudflare = { auto-ttl = true; };
    ttl = 300;
    type = "A";
    value = "137.184.94.125";
  };

  wiki = {
    octodns.cloudflare = {
      auto-ttl = true;
      comment = "Andref Wiki";
    };
    ttl = 60;
    type = "A";
    value = generated.serverref.ipAddress;
  };

  "hello.serverref" = {
    octodns.cloudflare = {
      auto-ttl = true;
      comment = "Serverref Test Endpoint";
    };
    ttl = 60;
    type = "A";
    value = generated.serverref.ipAddress;
  };

  tilde = {
    octodns.cloudflare = {
      auto-ttl = true;
      comment = "Tilde but using nix";
    };
    ttl = 60;
    type = "A";
    value = generated.serverref.ipAddress;
  };

  radicle = {
    octodns.cloudflare = {
      auto-ttl = true;
      comment = "Radicle";
    };
    ttl = 60;
    type = "A";
    value = generated.serverref.ipAddress;
  };

  "manual.dev" = {
    octodns.cloudflare = {
      comment = "notion.so/Gas-Giants-85c15c0fbfde4fe4ab30182b3fdb930a?pvs=4#1eae2551a84e805e87c0e08db23fe95f";
    };
    ttl = 60;
    type = "A";
    value = "24.130.65.84";
  };

  "syncthing.ts" = {
    octodns.cloudflare = {
      auto-ttl = true;
      comment = "Tailscale IP for hydrogen-sulfide";
    };
    ttl = 60;
    type = "A";
    value = "100.110.15.98";
  };

  # Requires HTTPS; not sure if debug pages should require SSL
  #"public.testpage" = {
  #  octodns.cloudflare = {
  #    auto-ttl = true;
  #    comment = "Test page hosted in milky-way, should be publicly accessible";
  #  };
  #  ttl = 60;
  #  type = "A";
  #  value = generated.serverref.ipAddress;
  #};

  #"public-tailscale.testpage" = {
  #  octodns.cloudflare = {
  #    auto-ttl = true;
  #    comment = "Test page hosted in milky-way, should not be accessible without Tailscale";
  #  };
  #  ttl = 60;
  #  type = "A";
  #  value = generated.serverref.ipAddress;
  #};
}
//
(handles-to-records atproto-handles)
