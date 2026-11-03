# The nixosConfigurations output: each host's bootstrap system, which is bootstrap.nix plus
# the host's disks and hardware config. `root` is the config's source.
{
  lib,
  disko,
  root,
  mappers,
}:
lib.mapAttrs (
  host: mapper:
  lib.nixosSystem {
    specialArgs = { inherit host mapper; };
    modules = [
      ./bootstrap.nix
      disko.nixosModules.disko
      { disko.devices = mapper.diskoDevices; }
      "${root}/${mapper.hardwareConfigPath}"
    ];
  }
) mappers
