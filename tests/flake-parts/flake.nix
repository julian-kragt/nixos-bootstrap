# A flake-parts config using nixos-bootstrap's flake module, for tests/run.sh.
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    nixos-bootstrap.url = "path:../..";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { self, lib, ... }:
      {
        imports = [ inputs.nixos-bootstrap.flakeModules.default ];

        systems = [ ];

        flake.nixosConfigurations.myhost = inputs.nixpkgs.lib.nixosSystem {
          modules = [
            inputs.disko.nixosModules.disko
            ./hardware-configuration.nix
            {
              networking.hostName = "myhost";
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

              users.users.root.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA test" ];
              users.users.demo.isNormalUser = true;
            }
          ];
        };

        flake.bootstrapEntries =
          lib.mapAttrs
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
              inherit (self.nixosConfigurations) myhost;
            };
      }
    );
}
