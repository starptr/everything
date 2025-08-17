{
  description = "jellyfin-mpv-shim as a flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    jellyfin-mpv-shim = {
      url = "github:jellyfin/jellyfin-mpv-shim/v2.8.0";
      flake = false;
    };
    flake-utils.url = "github:numtide/flake-utils";
    pystray = {
      url = "github:moses-palmer/pystray/v0.19.5";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      jellyfin-mpv-shim,
      pystray,
      ...
    }@inputs:
    let
      system = "aarch64-darwin";
    in
    let
      pkgs = import nixpkgs {
        inherit system;
      };
    in
    {
      packages.${system} = {
        pystray =
          let
            pname = "pystray";
            version = "0.19.5";
          in
          pkgs.python312Packages.buildPythonPackage {
            inherit pname version;
            src = pystray;
            postPatch = ''
              substituteInPlace setup.py \
                --replace-fail "'sphinx >=1.3.1'" ""
            '';
            propagatedBuildInputs = with pkgs.python312Packages; [
              pillow
              six
            ];
          };
        jellyfin-mpv-shim =
          let
            pname = "jellyfin-mpv-shim";
            version = "2.8.0";
          in
          pkgs.python312Packages.buildPythonApplication {
            inherit pname version;
            src = pkgs.fetchPypi {
              inherit pname version;
              hash = "sha256-EANaNmvD8hcdGB2aoGemKvA9syS1VvIqGsP1jk0b+lE=";
            };
            propagatedBuildInputs = with pkgs.python312Packages; [
              jellyfin-apiclient-python
              python-mpv-jsonipc
              pillow
              # INFO: for gui to work on macOS, pyobjc needs to build. This is a blocking dep that is not yet available.
              #tkinter
              #self.packages.${system}.pystray 
            ];
            postPatch = ''
              substituteInPlace jellyfin_mpv_shim/conf.py \
                --replace "check_updates: bool = True" "check_updates: bool = False" \
                --replace "notify_updates: bool = True" "notify_updates: bool = False"
              # python-mpv renamed to mpv with 1.0.4
              substituteInPlace setup.py \
                --replace "python-mpv" "mpv" \
                --replace "mpv-jsonipc" "python_mpv_jsonipc"
            '';
            doCheck = false;
            pythonImportsCheck = [ "jellyfin_mpv_shim" ];
          };
        default = self.packages.${system}.jellyfin-mpv-shim;
      };
      formatter.${system} = pkgs.nixfmt-rfc-style;
    };
}
