# The nixosConfigurations output: each host's bootstrap system, which is bootstrap.nix plus
# the host's disks and hardware config.
{
  lib,
  disko,
  configFlake,
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
      "${configFlake}/${mapper.hardwareConfigPath}"
    ];
  }
) mappers
