{ pkgs, lib }: let
  yaml-lib = pkgs.callPackage ../lib/yaml.nix {};
in {
  config-directory = let
    generated = builtins.fromJSON (builtins.readFile ./../exports/jupiter/generated.json);
    nixie-ip-address = generated.nixie.ipAddress;
    configurations-by-file = lib.fix (self: {
      "andref.app.yaml" = import ./per-domain/andref.yaml.nix {
        inherit generated;
        configurations-by-file = self;
      };
      "production.yaml" = {
        providers = {
          config = {
            class = "octodns.provider.yaml.YamlProvider";
            directory = "."; # This means that our CWD must be the directory containing these files
            default_ttl = 3600;
            enforce_order = false;
          };
          cloudflare = {
            class = "octodns_cloudflare.CloudflareProvider";
            token = "env/CLOUDFLARE_TOKEN";
            min_ttl = 60;
          };
        };
        zones = {
          # This is a dynamic zone config. The source(s), here `config`, will be
          # queried for a list of zone names and each will dynamically be set up to
          # match the dynamic entry.
          "yart.me." = {
            sources = [ "config" ];
            targets = [ "cloudflare" ];
          };
          "yuto.ink." = self."production.yaml".zones."yart.me.";
          "yuto.sh." = self."production.yaml".zones."yart.me.";
          "yuto.tel." = self."production.yaml".zones."yart.me.";
          "yuto.wiki." = self."production.yaml".zones."yart.me.";
          "yut.to." = self."production.yaml".zones."yart.me.";
          "andref.app." = self."production.yaml".zones."yart.me.";
        };
      };
      "yart.me.yaml" = {
        "" = [
          {
            octodns = {
              cloudflare = {
                auto-ttl = true;
                comment = "this record was set by terraform from starptr/yart";
                ignored = true;
              };
            };
            ttl = 300;
            type = "ALIAS";
            value = "yart.vercel.app.";
          }
          {
            octodns = {
              cloudflare = {
                auto-ttl = true;
                comment = "Fastmail";
              };
            };
            ttl = 300;
            type = "MX";
            values = [
              {
                exchange = "in1-smtp.messagingengine.com.";
                preference = 10;
              }
              {
                exchange = "in2-smtp.messagingengine.com.";
                preference = 20;
              }
            ];
          }
          {
            octodns = {
              cloudflare = {
                auto-ttl = true;
                comment = "Fastmail spf";
              };
            };
            ttl = 300;
            type = "TXT";
            value = "v=spf1 include:spf.messagingengine.com ?all";
          }
        ];
        "*.cap" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
            };
          };
          ttl = 300;
          type = "A";
          value = "143.198.246.238";
        };
        "api" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
            };
          };
          ttl = 300;
          type = "CNAME";
          value = "now-playing.cap.yart.me.";
        };
        "fm1._domainkey" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
              comment = "Fastmail dkim";
            };
          };
          ttl = 300;
          type = "CNAME";
          value = "fm1.yart.me.dkim.fmhosted.com.";
        };
        "fm2._domainkey" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
              comment = "Fastmail dkim";
            };
          };
          ttl = 300;
          type = "CNAME";
          value = "fm2.yart.me.dkim.fmhosted.com.";
        };
        "fm3._domainkey" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
              comment = "Fastmail dkim";
            };
          };
          ttl = 300;
          type = "CNAME";
          value = "fm3.yart.me.dkim.fmhosted.com.";
        };
        "spotify" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
            };
          };
          ttl = 300;
          type = "CNAME";
          value = "spotify.yart.me.cdn.cloudflare.net.";
        };
        "uni2code" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
            };
          };
          ttl = 300;
          type = "CNAME";
          value = "uni2code.netlify.app.";
        };
      };
      "yut.to.yaml" = {
        "" = [
          {
            octodns = {
              cloudflare = {
                auto-ttl = true;
                proxied = true;
                ignored = true;
              };
            };
            ttl = 300;
            type = "AAAA";
            value = "100::";
          }
          {
            octodns = {
              cloudflare = {
                auto-ttl = true;
              };
            };
            ttl = 300;
            type = "MX";
            values = [
              {
                exchange = "eforward1.registrar-servers.com.";
                preference = 10;
              }
              {
                exchange = "eforward2.registrar-servers.com.";
                preference = 10;
              }
              {
                exchange = "eforward3.registrar-servers.com.";
                preference = 10;
              }
              {
                exchange = "eforward4.registrar-servers.com.";
                preference = 15;
              }
              {
                exchange = "eforward5.registrar-servers.com.";
                preference = 20;
              }
            ];
          }
          {
            octodns = {
              cloudflare = {
                auto-ttl = true;
              };
            };
            ttl = 300;
            type = "TXT";
            value = "v=spf1 include:spf.efwd.registrar-servers.com ~all";
          }
        ];
        "mc" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
            };
          };
          ttl = 300;
          type = "A";
          value = "152.67.224.194";
        };
      };
      "yuto.ink.yaml" = {
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
            comment = "Test page hosted in milky-way, should not be accessible without Tailscale";
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
      };
      "yuto.sh.yaml" = {
        "" = [
          {
            octodns = {
              cloudflare = {
                auto-ttl = true;
              };
            };
            ttl = 300;
            type = "A";
            value = "75.2.60.5";
          }
          {
            octodns = {
              cloudflare = {
                auto-ttl = true;
              };
            };
            ttl = 300;
            type = "MX";
            values = [
              {
                exchange = "eforward1.registrar-servers.com.";
                preference = 10;
              }
              {
                exchange = "eforward2.registrar-servers.com.";
                preference = 10;
              }
              {
                exchange = "eforward3.registrar-servers.com.";
                preference = 10;
              }
              {
                exchange = "eforward4.registrar-servers.com.";
                preference = 15;
              }
              {
                exchange = "eforward5.registrar-servers.com.";
                preference = 20;
              }
            ];
          }
          {
            octodns = {
              cloudflare = {
                auto-ttl = true;
              };
            };
            ttl = 300;
            type = "TXT";
            value = "v=spf1 include:spf.efwd.registrar-servers.com ~all";
          }
        ];
        "ts" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
            };
          };
          ttl = 300;
          type = "A";
          value = "100.66.149.91";
        };
        "ts2" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
            };
          };
          ttl = 300;
          type = "A";
          value = "100.101.227.126";
        };
        "www" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
            };
          };
          ttl = 300;
          type = "CNAME";
          value = "modest-euler-7ef43a.netlify.app.";
        };
        "x86_64.nix" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
              comment = "Nix Remote Builder running x86_64";
            };
          };
          ttl = 300;
          type = "A";
          value = "143.198.60.34";
        };
        "nixie" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
              comment = "Example record to demo taco's yaml injection";
            };
          };
          ttl = 60;
          type = "A";
          value = nixie-ip-address;
        };
        "hello-caddy.nixie" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
              comment = "Example caddy virtualHost from NixOS";
            };
          };
          ttl = 60;
          type = "A";
          value = nixie-ip-address;
        };
        "caddy.nixie" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
              comment = "Example caddy virtualHost from NixOS";
            };
          };
          ttl = 60;
          type = "A";
          value = nixie-ip-address;
        };
        "hello-nginx.nixie" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
              comment = "Example caddy virtualHost from NixOS";
            };
          };
          ttl = 60;
          type = "A";
          value = nixie-ip-address;
        };
        "simple-proxy.nixie" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
              comment = "Example caddy virtualHost from NixOS";
            };
          };
          ttl = 60;
          type = "A";
          value = nixie-ip-address;
        };
        "ra.nixie" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
              comment = "Example caddy virtualHost from NixOS";
            };
          };
          ttl = 60;
          type = "A";
          value = nixie-ip-address;
        };
        "so.nixie" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
              comment = "Example caddy virtualHost from NixOS";
            };
          };
          ttl = 60;
          type = "A";
          value = nixie-ip-address;
        };
        "komga.nixie" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
              comment = "Komga comic server";
            };
          };
          ttl = 60;
          type = "A";
          value = nixie-ip-address;
        };
        "sp.nixie" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
              comment = "Syncplay server";
            };
          };
          ttl = 60;
          type = "A";
          value = nixie-ip-address;
        };
        "acmechallenge" = {
          octodns = {
            cloudflare = {
              auto-ttl = true;
              comment = "For acme HTTP challenge";
            };
          };
          ttl = 60;
          type = "A";
          value = nixie-ip-address;
        };
      };
      "yuto.tel.yaml" = {};
      "yuto.wiki.yaml" = {
        "" = [
          {
            octodns = {
              cloudflare = {
                auto-ttl = true;
                proxied = true;
                ignored = true;
              };
            };
            ttl = 300;
            type = "AAAA";
            value = "100::";
          }
          {
            octodns = {
              cloudflare = {
                auto-ttl = true;
              };
            };
            ttl = 300;
            type = "MX";
            values = [
              {
                exchange = "eforward1.registrar-servers.com.";
                preference = 10;
              }
              {
                exchange = "eforward2.registrar-servers.com.";
                preference = 10;
              }
              {
                exchange = "eforward3.registrar-servers.com.";
                preference = 10;
              }
              {
                exchange = "eforward4.registrar-servers.com.";
                preference = 15;
              }
              {
                exchange = "eforward5.registrar-servers.com.";
                preference = 20;
              }
            ];
          }
          {
            octodns = {
              cloudflare = {
                auto-ttl = true;
              };
            };
            ttl = 300;
            type = "TXT";
            value = "v=spf1 include:spf.efwd.registrar-servers.com ~all";
          }
        ];
      };
    });
    configuration-files = builtins.mapAttrs (key: value:
      pkgs.writeTextFile {
        name = key;
        text = yaml-lib.toYAML value;
      }
    ) configurations-by-file;
    folder-containing-all-files = pkgs.runCommand "octodns-config" {} ''
      mkdir -p $out
      ${lib.concatMapAttrsStringSep "\n" (filename: file: ''
        ln -s ${file} $out/${filename}
      '') configuration-files}
    '';
  in folder-containing-all-files;
}