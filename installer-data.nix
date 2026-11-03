# The installerData output: what installers read, built from the checked mappers. It must
# stay JSON-safe, and diskoDevices itself holds functions JSON can't print.
{ lib, mappers }:
lib.mapAttrs (_: mapper: {
  inherit (mapper) system rootAuthorizedKeys hardwareConfigPath users;
  disks = lib.mapAttrs (_: d: d.device) mapper.diskoDevices.disk or { };
}) mappers
