# Example config for nixos-bootstrap: the default of its `config` input and
# the reference for README.md. One host, `example`, a QEMU VM with one disk.
# A real config replaces this one with --override-input or a wrapper flake.
{
  description = "nixos-bootstrap example config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      ...
    }:
    let
      lib = nixpkgs.lib;
    in
    {
      # The full config.
      nixosConfigurations.example = lib.nixosSystem {
        modules = [
          disko.nixosModules.disko
          ./hardware-configuration.nix
          {
            networking.hostName = "example";
            system.stateVersion = "25.11";
            boot.loader.systemd-boot.enable = true;

            disko.devices.disk.main = {
              type = "disk";
              device = "/dev/vda";
              content = {
                type = "gpt";
                partitions = {
                  ESP = {
                    size = "512M";
                    type = "EF00";
                    content = {
                      type = "filesystem";
                      format = "vfat";
                      mountpoint = "/boot";
                      mountOptions = [ "umask=0077" ];
                    };
                  };
                  root = {
                    size = "100%";
                    content = {
                      type = "filesystem";
                      format = "ext4";
                      mountpoint = "/";
                    };
                  };
                };
              };
            };

            services.openssh.enable = true;
            users.users.root.openssh.authorizedKeys.keys = [
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIReplaceWithYourOwnPublicKeyReplaceWithYourOw example"
            ];
            users.users.demo.isNormalUser = true;
          }
        ];
      };

      # The `bootstrap` output: what nixos-bootstrap needs from every host above, taken
      # from the evaluated full config.
      bootstrap = lib.mapAttrs (
        host:
        { config, ... }:
        {
          system = config.nixpkgs.hostPlatform.system;
          diskoDevices = config.disko.devices;
          rootAuthorizedKeys = config.users.users.root.openssh.authorizedKeys.keys;
          hardwareConfigPath = "hardware-configuration.nix";
          users = config.users.users;
        }
      ) self.nixosConfigurations;
    };
}
