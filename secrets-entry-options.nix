# The fixed shape of `<secrets flake>#secretsEntry`, as module options: every field
# must be given and any other field is an error. The user paths and user templates
# may be null, but only where userMode allows it; secrets.nix checks that and the
# other rules between fields.
{ lib, root }:
let
  inherit (lib) mkOption types;

  # Relative, without empty, `.` or `..` segments, so one path names one place and
  # the checks between paths in secrets.nix can compare strings.
  isRelative =
    p:
    p != ""
    && !lib.hasPrefix "/" p
    && lib.all (s: s != "" && s != "." && s != "..") (lib.splitString "/" p);

  directory =
    types.addCheck types.str (p: isRelative p && lib.filesystem.pathIsDirectory "${root}/${p}")
    // {
      description = "path of an existing directory, relative to the secrets repository";
    };

  file =
    types.addCheck types.str (p: isRelative p && lib.filesystem.pathIsRegularFile "${root}/${p}")
    // {
      description = "path of an existing file, relative to the secrets repository";
    };
in
{
  options = {
    userMode = mkOption {
      type = types.enum [
        "per-host"
        "shared"
        "both"
      ];
      description = ''
        How users' secrets are kept: "per-host", one file per host and user; "shared", one
        file per user for all the hosts they are on; "both", each user has both files.
      '';
    };

    hostPath = mkOption {
      type = directory;
      description = "The directory of the hosts' own files, `<hostPath>/<host>.yaml`.";
    };

    hostUserPath = mkOption {
      type = types.nullOr directory;
      description = ''The directory of per-host user files, `<hostUserPath>/<host>-<user>.yaml`. null when userMode is "shared".'';
    };

    sharedUserPath = mkOption {
      type = types.nullOr directory;
      description = ''The directory of shared user files, `<sharedUserPath>/<user>.yaml`. null when userMode is "per-host".'';
    };

    hostTemplatePath = mkOption {
      type = file;
      description = "The template of every host file.";
    };

    hostUserTemplatePath = mkOption {
      type = types.nullOr file;
      description = ''The template of every per-host user file. null when userMode is "shared".'';
    };

    sharedUserTemplatePath = mkOption {
      type = types.nullOr file;
      description = ''The template of every shared user file. null when userMode is "per-host".'';
    };
  };
}
