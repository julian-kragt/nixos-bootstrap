# The installerData output: what installers read, built from the checked entries. It must
# stay JSON-safe, and diskoDevices itself holds functions JSON can't print. disks comes from
# the bootstrap system, so it names the devices of the merged layout that an install wipes.
{
  lib,
  entries,
  nixosConfigurations,
}:
lib.mapAttrs (
  host: entry:
  let
    disks = lib.mapAttrs (_: d: d.device) nixosConfigurations.${host}.config.disko.devices.disk;
  in
  {
    inherit (entry) system rootAuthorizedKeys hardwareConfigPath;
    # The normal users, without their passwords, keys or packages.
    users = lib.mapAttrs (_: u: { inherit (u) name uid home; }) (
      lib.filterAttrs (_: u: u.isNormalUser) entry.users
    );
    disks = lib.throwIf (disks == { }) "nixos-bootstrap: the disko layout of `${host}` has no disks." disks;
  }
) entries
