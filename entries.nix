# The config's bootstrapEntries.<host>, each checked against entry-options.nix.
{ lib, configFlake }:
let
  entries =
    configFlake.bootstrapEntries
      or (throw "nixos-bootstrap: the config flake has no `bootstrapEntries` output (see README.md)");

  checkEntry =
    host: entry:
    (lib.evalModules {
      prefix = [
        "bootstrapEntries"
        host
      ];
      modules = [
        (import ./entry-options.nix { inherit lib configFlake; })
        {
          _file = "the config's bootstrapEntries.${host}";
          config = entry;
        }
      ];
    }).config;
in
lib.mapAttrs checkEntry entries
