# A secrets repository for the tests. run.sh gives it nixpkgs and this checkout.
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-bootstrap.url = "path:../..";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nixos-bootstrap,
      ...
    }:
    {
      installerSecretsData = nixos-bootstrap.lib.secretsInstallerData inputs;

      # The layout: both kinds of user file, with the login password in the per-host ones.
      secretsEntry = {
        userMode = "both";
        hostPath = "hosts";
        hostUserPath = "host-users";
        sharedUserPath = "users";
        hostTemplatePath = "templates/host.yaml";
        hostUserTemplatePath = "templates/user.yaml";
        sharedUserTemplatePath = "templates/shared-user.yaml";
      };

      # The path of each kind of file for host `h` and user `u`, from lib.secretsLayout.
      paths =
        let
          layout = nixos-bootstrap.lib.secretsLayout {
            inherit (nixpkgs) lib;
            secretsFlake = self;
          };
        in
        {
          host = layout.hostFile "h";
          hostUser = layout.hostUserFile "h" "u";
          sharedUser = layout.sharedUserFile "u";
          home = layout.homeFile "h" "u";
          password = layout.passwordFile "h" "u";
        };
    };
}
