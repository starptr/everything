# Set tealdeer config
{ ... }:
{
  config = {
    programs.tealdeer = {
      enable = true;
      settings = {
        display = {
          compact = true;
        };
      };
    };
  };
}
