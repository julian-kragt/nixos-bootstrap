# A secrets flake's layout: its `secretsEntry` output, checked against
# secrets-entry-options.nix and the rules between fields below, with the path of each
# kind of secret file. Paths are relative to the repository.
{ lib, secretsFlake }:
let
  # The flake's source, which the paths are relative to.
  root = secretsFlake.outPath;
  entry =
    secretsFlake.secretsEntry
      or (throw "nixos-bootstrap: the secrets flake has no `secretsEntry` output (see README.md)");

  e =
    (lib.evalModules {
      prefix = [ "secretsEntry" ];
      modules = [
        (import ./secrets-entry-options.nix { inherit lib root; })
        {
          _file = "the secrets flake's secretsEntry";
          config = entry;
        }
      ];
    }).config;

  hasHostUser = lib.elem e.userMode [
    "per-host"
    "both"
  ];
  hasShared = lib.elem e.userMode [
    "shared"
    "both"
  ];

  # The user's login password is the top-level `hashedPassword` of one kind of user
  # file. Templates are flat YAML, so a line match finds it without parsing.
  hasPassword =
    template:
    template != null
    && lib.any (l: builtins.match "hashedPassword[[:space:]]*:.*" l != null) (
      lib.splitString "\n" (builtins.readFile "${root}/${template}")
    );
  hostUserPassword = hasPassword e.hostUserTemplatePath;
  sharedPassword = hasPassword e.sharedUserTemplatePath;

  dirs = lib.filter (p: p != null) [
    e.hostPath
    e.hostUserPath
    e.sharedUserPath
  ];
  inside = dir: p: p == dir || lib.hasPrefix "${dir}/" p;
  overlapping = lib.filter ({ a, b }: inside a b || inside b a) (
    lib.concatLists (lib.imap0 (i: a: map (b: { inherit a b; }) (lib.drop (i + 1) dirs)) dirs)
  );
  templates = lib.filter (p: p != null) [
    e.hostTemplatePath
    e.hostUserTemplatePath
    e.sharedUserTemplatePath
  ];

  # Set exactly when userMode uses it.
  setFor = name: wanted: {
    assertion = (e.${name} != null) == wanted;
    message =
      if wanted then
        "`${name}` is required when userMode is \"${e.userMode}\""
      else
        "`${name}` must be null when userMode is \"${e.userMode}\"";
  };

  checks = [
    (setFor "hostUserPath" hasHostUser)
    (setFor "hostUserTemplatePath" hasHostUser)
    (setFor "sharedUserPath" hasShared)
    (setFor "sharedUserTemplatePath" hasShared)
    {
      assertion = overlapping == [ ];
      message =
        let
          o = lib.head overlapping;
        in
        "the directories `${o.a}` and `${o.b}` must be different and not inside each other";
    }
    {
      assertion = lib.all (t: lib.all (d: !inside d t) dirs) templates;
      message = "templates must not be inside hostPath, hostUserPath or sharedUserPath, where they would read as secret files";
    }
    {
      assertion = !(hostUserPassword && sharedPassword);
      message = "only one of hostUserTemplatePath and sharedUserTemplatePath may have a top-level `hashedPassword`";
    }
  ];
  failed = lib.filter (c: !c.assertion) checks;

  data = {
    inherit (e)
      userMode
      hostPath
      hostUserPath
      sharedUserPath
      hostTemplatePath
      hostUserTemplatePath
      sharedUserTemplatePath
      ;
    # The user template whose files hold the login password, or null.
    passwordTemplate =
      if hostUserPassword then
        e.hostUserTemplatePath
      else if sharedPassword then
        e.sharedUserTemplatePath
      else
        null;
  };

  hostUserFile = host: user: if hasHostUser then "${e.hostUserPath}/${host}-${user}.yaml" else null;
  sharedUserFile = user: if hasShared then "${e.sharedUserPath}/${user}.yaml" else null;
in
# Every field is read here, so a missing one fails now, not when a path is first used.
lib.throwIf (failed != [ ]) "nixos-bootstrap: secretsEntry: ${(lib.head failed).message}" (
  builtins.deepSeq data {
    inherit data;
    layout = data // {
      inherit hostUserFile sharedUserFile;
      hostFile = host: "${e.hostPath}/${host}.yaml";
      # Home Manager's default file: the shared one where there is one.
      homeFile = host: user: if hasShared then sharedUserFile user else hostUserFile host user;
      passwordFile =
        host: user:
        if hostUserPassword then
          hostUserFile host user
        else if sharedPassword then
          sharedUserFile user
        else
          null;
    };
  }
)
