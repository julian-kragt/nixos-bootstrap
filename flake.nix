# nixos-bootstrap: the first, minimal NixOS system of a host, which
# nixos-anywhere installs before the full config can be deployed.
#
# Everything host-specific comes from the host's entry in the config flake,
# `bootstrapEntries.<host>` (contract: README.md, checked against entry-options.nix).
# The config takes this flake as an input and adds the outputs below to its own:
#
#   nix eval --json <config>#installerData.<host>
#   nixos-anywhere --flake <config>#<host>-bootstrap ...
#
#   nixosConfigurations.<host>-bootstrap  the bootstrap system for <host>
#   installerData.<host>                  bootstrapEntries.<host> checked, with disks in place of diskoDevices, JSON-safe for installers
{
  description = "nixos-bootstrap: the first, minimal NixOS install of a host, driven by its config's bootstrapEntries output";

  outputs =
    _:
    let
      # `inputs` are the config flake's: nixpkgs and the disko that evaluated
      # its disko.devices, so this flake has no inputs of its own.
      outputsFor =
        {
          self,
          nixpkgs,
          disko,
          ...
        }:
        let
          lib = nixpkgs.lib;
          configFlake = self;
          entries = import ./entries.nix { inherit lib configFlake; };
          nixosConfigurations = import ./nixos-configurations.nix {
            inherit
              lib
              disko
              configFlake
              entries
              ;
          };
        in
        {
          systems = lib.mapAttrs' (host: lib.nameValuePair "${host}-bootstrap") nixosConfigurations;
          installerData = import ./installer-data.nix { inherit lib entries nixosConfigurations; };
        };
    in
    {
      lib = {
        systems = inputs: (outputsFor inputs).systems;
        installerData = inputs: (outputsFor inputs).installerData;
      };

      # For flake-parts configs: adds both outputs to the flake.
      flakeModules.default =
        { inputs, ... }:
        {
          flake.nixosConfigurations = (outputsFor inputs).systems;
          flake.installerData = (outputsFor inputs).installerData;
        };
    };
}
