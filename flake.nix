# nixos-bootstrap: the first, minimal NixOS system of a host, which
# nixos-anywhere installs before the full config can be deployed.
#
# Everything host-specific comes from the config flake's mapper,
# `bootstrap.<host>` (contract: README.md, checked against entry-options.nix). The
# config is the `config` input: pass yours instead of editing this file.
#
#   nix eval --json .#installerData.<host> --override-input config <flake ref>
#   nixos-anywhere --flake <wrapper flake>#<host> ...   (see README.md)
#
#   nixosConfigurations.<host>  the bootstrap system for <host>
#   installerData.<host>        bootstrap.<host> checked, with disks in place of diskoDevices, JSON-safe for installers
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
      configFlake = config;
      mappers = import ./entries.nix { inherit lib configFlake; };
      nixosConfigurations = import ./nixos-configurations.nix {
        inherit
          lib
          disko
          configFlake
          mappers
          ;
      };
    in
    {
      inherit nixosConfigurations;
      installerData = import ./installer-data.nix { inherit lib mappers nixosConfigurations; };
    };
}
