{ config, modulesPath, lib, pkgs, ... }:
  let
    generated = builtins.fromJSON (builtins.readFile ./../../../exports/jupiter/generated.json);
    generated-serverref-data-from-pulumi = generated.serverref;
    hostKeys-by-name = {
      # INFO: deploy-rs cannot confirm activation if the first two attrsets are not in the following order by key!
      "00_ssh_host_rsa" = {
        bits = 4096;
        path = "/etc/ssh/ssh_host_rsa_key";
        type = "rsa";
      };
      "01_ssh_host_ed25519" = {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      };
      "10_key_for_radicle" = {
        path = "/etc/ssh/key_for_radicle";
        type = "ed25519";
        comment = "radicle";
      };
    };
  in
  {
    imports = lib.optional (builtins.pathExists ./do-userdata.nix) ./do-userdata.nix ++ [
      (modulesPath + "/virtualisation/digital-ocean-config.nix")
    ];

    nix = {
      settings.experimental-features = [ "nix-command" "flakes" ];
      settings.trusted-public-keys = [
        "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
      settings.trusted-substituters = [
        "https://devenv.cachix.org"
        "https://nix-community.cachix.org"
      ];
    };

    system.stateVersion = "23.11"; # Do not change lightly!

    # Config from the base image
    swapDevices = [
      {
        device = "/swapfile";
        size = 3072;
      }
    ];

    fileSystems."/nix" = {
      device = "/dev/disk/by-id/scsi-0DO_Volume_${generated-serverref-data-from-pulumi.nix-store-volume}";
      neededForBoot = true;
      options = [ "noatime" ];
    };

    environment.defaultPackages = [
      pkgs.git
      pkgs.vim
      pkgs.htop
    ];

    users.mutableUsers = true;
    users.defaultUserShell = pkgs.bashInteractive;
    users.users = {
      yuto = {
        isNormalUser = true;
        shell = pkgs.bash;
        description = "Yuto";
        password = "";
        createHome = true;
        homeMode = "755";
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = [
          "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDLrT2/gQXhOz4E4xSphB8EXouild5qNOnZ6ZVXuTnf167z8xxSB10mxNey2gKDaIVig6I/tRFeYy6/N/QutbBlKI/+GNPjGCcVJI0hf7fTZGL4caTW8ggcXRz4LAsFp3JBf6Li0FVrGz5ojD0Etbl54BDn033q/tlVRhme5bXJ6s73yRg04kqdQsWVBRJwyzbUUmCQPrZd9i5Nh4QFVuhZljEyUWIStajE+c9v8OOiY1svv+XjKBjyWphP16HqgzvnEDf5+MQ5AUxE05IvJx43UY43CKTe3evzt4F/IqSdYwYGIQ55DaseRmf5zmHLU8MTTkksmOPQEzJL0nBzAmxyGV3PsMYPoIN+1/gJmxCO6ZaaCxYr9SFK/yoRW5e0PFX433xPhNsITBq7jUrVg6BQ/lr0ntRfvd7pRhFq8v02R3jWokL/99skxp1kjVF42bXEJXYPpHF3XAUhYscjOwmWj8dJgsIsSIKIjh7gRVYxQGrZQXOcJQjMytFgXy7fWHM= yuto@Yutos-MacBook-Pro.local" # Yuto's Sodium
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPtVvX9uhSWD1DPBIRqgkNzFXqjdqvWB/WtDy4seaiJl" # 1Password "ssh key - main"
        ];
      };
      awang = { isNormalUser = true; homeMode = "755"; };
      bigpapalikescheese = { isNormalUser = true; homeMode = "755"; };
      blizz = { isNormalUser = true; homeMode = "755"; };
      cookiedamonstuh = { isNormalUser = true; homeMode = "755"; };
      disguise = { isNormalUser = true; homeMode = "755"; };
      edawg = { isNormalUser = true; homeMode = "755"; };
      emerald = { isNormalUser = true; homeMode = "755"; };
      geb = { isNormalUser = true; homeMode = "755"; };
      jjonn = { isNormalUser = true; homeMode = "755"; };
      kale = { isNormalUser = true; homeMode = "755"; };
      nugnug = { isNormalUser = true; homeMode = "755"; };
      pteronatyl = { isNormalUser = true; homeMode = "755"; };
      uraniumra = { isNormalUser = true; homeMode = "755"; };
      starptr = { isNormalUser = true; homeMode = "755"; linger = true; openssh.authorizedKeys.keyFiles = [ ./../../../tilderef/keys/starptr/id_rsa-sodium.pub ]; };
      yart = { isNormalUser = true; homeMode = "755"; };
    };

    systemd.user.services.example-service = {
      enable = true;
      #after = [ "network.target" ];
      wantedBy = [ "default.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.uutils-coreutils-noprefix}/bin/true";
        Type = "oneshot";
      };
    };

    # Let's Encrypt
    # see https://discourse.nixos.org/t/nixos-nginx-acme-ssl-certificates-for-multiple-domains/19608/3 for an example
    security.acme = {
      acceptTerms = true;
      defaults = {
        email = "acme.management@yart.me";
        dnsProvider = "cloudflare";
      };
    };
    security.sudo.wheelNeedsPassword = false;

    networking.firewall = {
      enable = true;
      allowedTCPPorts = [ 22 80 443 ];
      allowedUDPPorts = [ 443 ];

      # Through the /rp slug in nginx, expose ports 30000-30999
      allowedTCPPortRanges = [
        { from = 30000; to = 30999; }
      ];
      allowedUDPPortRanges = [
        { from = 30000; to = 30999; }
      ];
    };

    #services.dbus = {
    #  enable = true;
    #};
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = true;
        UsePAM = true;
      };
      hostKeys = builtins.attrValues hostKeys-by-name;
    };

    services.radicle = {
      enable = true;
      httpd = {
        enable = true;
        nginx = {
          serverName = "radicle.andref.app";
          enableACME = true;
          forceSSL = true;
        };
      };
      publicKey = hostKeys-by-name."10_key_for_radicle".path + ".pub";
      privateKeyFile = hostKeys-by-name."10_key_for_radicle".path;
      settings = {
        node.seedingPolicy.default = "block";
      };
    };

    # Serverreff-specific config
    services.nginx = {
      enable = true;
      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts."hello.serverref.andref.app" = {
        enableACME = true;
        addSSL = true;
        locations."/".extraConfig = ''
          default_type text/html;
          return 200 "<!DOCTYPE html><h1>Hello from serverref!</h1>\n";
        '';
      };
      virtualHosts."wiki.andref.app" = {
        enableACME = true;
        addSSL = true;
      };
      virtualHosts."andref.app" = {
        enableACME = true;
        forceSSL = true;
        root = ./../../../tilderef/build/andref-homepages/root;
      };
      virtualHosts."tilde.andref.app" = {
        enableACME = true;
        forceSSL = true;
        root = ./../../../tilderef/build/andref-homepages/tilde;
        locations = {
          "~ ^/~(.+?)(/.*)?$" = {
            alias = "/home/$1/public_html$2";
            index = "index.html index.htm";
            extraConfig = ''
              autoindex on;
            '';
          };
          "~ ^/disable-tildepage-index/~(.+?)(/.*)?$" = {
            alias = "/home/$1/public_html$2";
            index = "effectively-disable-index-ah5nnGv3BFj4sAJx.html";
            extraConfig = ''
              autoindex on;
            '';
          };

          #location ~ ^/status-coffee {
	        #	root /home/starptr/status-ref/build_html;
	        #	try_files /status.html =404;
	        #	autoindex on;
	        #}

        }
        // 
        # We want the following, but nginx doesn't support $1 in the port for a proxy_pass
        #"~ ^/rp/(30[0-9][0-9][0-9])/(.*)$" = {
        #  proxyPass = "http://127.0.0.1:$1/$2";
        #};
        # So we inline every port betwen 30000 and 30999 literally like:
        #"~ ^/rp/30000/(.*)$" = {
        #  proxyPass = "http://127.0.0.1:30000/$1";
        #};
        # and generating this chunk for each port.
        (builtins.listToAttrs (map (port: {
          name = "~ ^/rp/${toString port}/(.*)$";
          value = {
            proxyPass = "http://127.0.0.1:${toString port}/$1";
          };
        }) (builtins.genList (i: i + 30000) 1000))); # This generates the list 30000 to 30999, inclusive
      };
    };
    systemd.services.nginx.serviceConfig.ProtectHome = false;

    services.dokuwiki = {
      webserver = "nginx";
      sites = {
        "wiki.andref.app" = {
          settings = {
            #baseurl = "https://wiki.andref.app";
            title = "wikiref";
            useacl = true;
            superuser = "admin";
            useheading = true;
            userewrite = 1;
            authtype = "oauth";
            showuseras = "username_link";
            disableactions = [ "register" "profile" ];
            plugin.oauth = {
              register-on-auth = true;
            };
            plugin.oauthdiscordserver = {
              # Client ID
              #key = "";
              # Client Secret
              #secret = "";
              # Ensure that the redirect URL is set on the Discord dev portal: https://discord.com/developers/applications/779903945065234442/oauth2
              # Server ID
              #serverID = "";
            };
          };
          plugins = [
            (builtins.trace "Path to dokuwiki-plugin-oauth: ${pkgs.dokuwiki-plugin-oauth.outPath}" pkgs.dokuwiki-plugin-oauth)
            pkgs.dokuwiki-plugin-oauthdiscordserver
          ];
        };
      };
    };

    services.cursor-server.enable = true;

    # TODO: move to a normal user service under starptr
    systemd.services.fleeting = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      description = "The fleeting discord bot";
      serviceConfig = {
        Type = "exec";
        User = "yuto";
        Restart = "on-failure";

        # Point to the fleeting binary
        WorkingDirectory = ''/home/yuto/src/fleeting'';
        ExecStart = ''/home/yuto/src/fleeting/target/debug/fleeting'';
      };
    };

    sops = {
      secrets."client_id" = {
        mode = "0400";
        sopsFile = ./../../../secrets/discord-oauth/wikiref.yaml;
      };
      secrets."client_secret" = {
        mode = "0400";
        sopsFile = ./../../../secrets/discord-oauth/wikiref.yaml;
      };
      secrets."server_id" = {
        mode = "0400";
        sopsFile = ./../../../secrets/discord/andref.yaml;
      };
    };
  }