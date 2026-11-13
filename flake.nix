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
#
# A secrets repository describes its layout the same way, as its flake's `secretsEntry`
# output (checked against secrets-entry-options.nix): lib.secretsLayout gives configs its
# file paths, and lib.secretsInstallerData gives installers the data, as the repository's
# `installerSecretsData` output.
{
  description = "nixos-bootstrap: the first, minimal NixOS install of a host, driven by its config's bootstrapEntries output";

  outputs =
    _:
    let
      # `inputs` are the config flake's: nixpkgs and the disko that evaluated
      # its disko.devices, so this flake has no inputs of its own.
      outputsFor =
        inputs@{ self, ... }:
        let
          # A throw, because some versions of nix report a missing function argument
          # here as the flake not having the attribute the user asked for.
          input =
            name:
            inputs.${name}
              or (throw "nixos-bootstrap: the config flake has no `${name}` input (see README.md)");
          inherit (input "nixpkgs") lib;
          disko = input "disko";
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

        # A secrets repository's layout, from its flake's `secretsEntry` output (contract:
        # README.md, checked against secrets-entry-options.nix). `secretsFlake` is that
        # flake, such as a config's input; the result has the checked fields and the path
        # of each kind of secret file.
        secretsLayout = { lib, secretsFlake }: (import ./secrets.nix { inherit lib secretsFlake; }).layout;

        # The same layout as JSON-safe data, for the secrets repository's own flake to
        # output as `installerSecretsData`: `inputs` are that flake's, with `nixpkgs`.
        secretsInstallerData =
          inputs@{ self, ... }:
          (import ./secrets.nix {
            inherit
              (inputs.nixpkgs
                or (throw "nixos-bootstrap: the secrets flake has no `nixpkgs` input (see README.md)")
              )
              lib
              ;
            secretsFlake = self;
          }).data;
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
