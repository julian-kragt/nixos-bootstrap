# The config's bootstrap.<host> entries, each checked against entry-options.nix.
{ lib, configFlake }:
let
  entries =
    configFlake.bootstrap
      or (throw "nixos-bootstrap: the config flake has no `bootstrap` output (see README.md)");

  checkEntry =
    host: entry:
    (lib.evalModules {
      prefix = [
        "bootstrap"
        host
      ];
      modules = [
        (import ./entry-options.nix { inherit lib configFlake; })
        {
          _file = "the config's bootstrap.${host}";
          config = entry;
        }
      ];
    }).config;
in
lib.mapAttrs checkEntry entries
