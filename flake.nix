# nixos-bootstrap: the first, minimal NixOS system of a host, which
# nixos-anywhere installs before the full config can be deployed.
#
# Everything host-specific comes from the config flake's mapper,
# `bootstrap.<host>` (contract: README.md, checked by mapper.nix). The config
# is the `config` input: pass yours instead of editing this file.
#
#   nix eval --json .#installerData.<host> --override-input config <flake ref>
#   nixos-anywhere --flake <wrapper flake>#<host> ...   (see README.md)
#
#   nixosConfigurations.<host>  the bootstrap system for <host>
#   installerData.<host>        bootstrap.<host> checked, without diskoDevices, JSON-safe for installers
{
  description = "nixos-bootstrap: the first, minimal NixOS install of a host, driven by its config's mapper";

  inputs = {
    # The parameter: the config flake to bootstrap. Override it, never edit it.
    config.url = "path:./example";
    nixpkgs.follows = "config/nixpkgs";
    # The disko that evaluated the config's disko.devices.
    disko.follows = "config/disko";
  };

  outputs =
    {
      config,
      nixpkgs,
      disko,
      ...
    }:
    let
      lib = nixpkgs.lib;

      entries =
        config.bootstrap
          or (throw "nixos-bootstrap: the config flake has no `bootstrap` output (see README.md)");

      # Checks the whole entry against mapper.nix.
      checkEntry =
        host: entry:
        let
          checked =
            (lib.evalModules {
              prefix = [
                "bootstrap"
                host
              ];
              modules = [
                (import ./mapper.nix {
                  inherit lib;
                  root = config;
                })
                {
                  _file = "the config's bootstrap.${host}";
                  config = entry;
                }
              ];
            }).config;
        in
        builtins.seq checked.diskoDevices checked;

      # Without diskoDevices: the evaluated layout holds functions JSON can't print.
      mkInstallerData = host: entry: removeAttrs (checkEntry host entry) [ "diskoDevices" ];

      mkBootstrap =
        host: entry:
        let
          mapper = checkEntry host entry;
        in
        lib.nixosSystem {
          specialArgs = { inherit host mapper; };
          modules = [
            ./bootstrap.nix
            disko.nixosModules.disko
            { disko.devices = entry.diskoDevices; }
            "${config}/${mapper.hardwareConfigPath}"
          ];
        };
    in
    {
      installerData = lib.mapAttrs mkInstallerData entries;
      nixosConfigurations = lib.mapAttrs mkBootstrap entries;
    };
}
