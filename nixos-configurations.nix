# The nixosConfigurations output: each host's bootstrap system, which is bootstrap.nix plus
# the host's disks and hardware config.
{
  lib,
  disko,
  configFlake,
  entries,
}:
lib.mapAttrs (
  host: entry:
  lib.nixosSystem {
    specialArgs = { inherit host entry; };
    modules = [
      ./bootstrap.nix
      disko.nixosModules.disko
      { disko.devices = entry.diskoDevices; }
      "${configFlake}/${entry.hardwareConfigPath}"
    ];
  }
) entries
