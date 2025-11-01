{ configurations-by-file, generated }: {
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
}