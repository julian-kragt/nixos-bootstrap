# The fixed shape of `<config>#bootstrap.<host>`, as module options: every field
# is required and any other field is an error. flake.nix evaluates each entry
# against these options. `root` is the config's source.
{ lib, root }:
let
  inherit (lib) mkOption types;

  # Lists and attrsets would otherwise default to empty when left out. The module
  # system rebuilds types holding submodules with substSubModules, so keep it there too.
  required =
    type:
    type
    // {
      emptyValue = { };
      substSubModules = m: required (type.substSubModules m);
    };
in
{
  options = {
    system = mkOption {
      type = types.enum lib.platforms.linux;
      description = ''The host's platform, such as "x86_64-linux".'';
    };

    diskoDevices = mkOption {
      type = required types.attrs;
      description = "The host's disko.devices.";
    };

    rootAuthorizedKeys = mkOption {
      type = types.nonEmptyListOf types.str;
      description = "Root's SSH keys on the bootstrap system.";
    };

    hardwareConfigPath = mkOption {
      type =
        types.addCheck types.str (
          p:
          !lib.hasPrefix "/" p
          && !lib.elem ".." (lib.splitString "/" p)
          && lib.filesystem.pathIsRegularFile "${root}/${p}"
        )
        // {
          description = "path of an existing file, relative to the config root";
        };
      description = "The host's hardware config. Imported into the bootstrap system; installers write a generated one here.";
    };

    users = mkOption {
      type = required (
        types.attrsOf (
          types.submodule {
            # The other NixOS user options: accepted, never forced.
            freeformType = types.lazyAttrsOf types.raw;
            options = {
              isNormalUser = mkOption { type = types.bool; };
              # null: NixOS allocates one, as in the full config.
              uid = mkOption { type = required (types.nullOr types.ints.unsigned); };
              home = mkOption { type = types.path; };
            };
          }
        )
      );
      # Only this reaches the bootstrap system and installerData: no passwords, keys or packages.
      apply =
        users:
        lib.mapAttrs (_: u: { inherit (u) uid home; }) (lib.filterAttrs (_: u: u.isNormalUser) users);
      description = "The host's config.users.users. Its normal users are created on the bootstrap system with their uid and home, and no password or keys.";
    };
  };
}
