# Example config for nixos-bootstrap: the reference for README.md and a plain
# flake to test it with. One host, `example`, a QEMU VM with one disk.
{
  description = "nixos-bootstrap example config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-bootstrap.url = "path:..";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nixos-bootstrap,
      ...
    }:
    {
      # The full config, plus the bootstrap systems nixos-bootstrap generates.
      nixosConfigurations = {
        example = nixpkgs.lib.nixosSystem {
          modules = [
            inputs.disko.nixosModules.disko
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
      }
      // nixos-bootstrap.lib.systems inputs;

      installerData = nixos-bootstrap.lib.installerData inputs;

      # What nixos-bootstrap needs from each host named on the last line, taken from
      # the evaluated full config. Name the hosts: mapping over all of
      # self.nixosConfigurations is infinite recursion, as it holds the generated systems.
      bootstrapEntries =
        nixpkgs.lib.mapAttrs
          (
            _:
            { config, ... }:
            {
              system = config.nixpkgs.hostPlatform.system;
              diskoDevices = config.disko.devices;
              rootAuthorizedKeys = config.users.users.root.openssh.authorizedKeys.keys;
              hardwareConfigPath = "hardware-configuration.nix";
              users = config.users.users;
            }
          )
          {
            inherit (self.nixosConfigurations) example;
          };
    };
}
