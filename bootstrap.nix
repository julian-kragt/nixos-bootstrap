# The bootstrap system: root SSH access, the host's users and the tooling
# installers need on the target. `mapper` is the config's bootstrap.<host>,
# checked against entry-options.nix; nixos-configurations.nix adds the host's
# disks and hardware config next to this module.
{
  host,
  mapper,
  config,
  lib,
  pkgs,
  ...
}:
{
  # Wins over the hardware config's lib.mkDefault; a different plain value there is an error.
  nixpkgs.hostPlatform = mapper.system;

  networking.hostName = host;
  # Nothing stateful runs here; the full config sets the host's own stateVersion.
  system.stateVersion = lib.trivial.release;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # systemd-boot installs to /boot; without this, a layout with its ESP elsewhere
  # only fails at the bootloader install, after the disk is wiped.
  assertions = [
    {
      assertion = config.fileSystems."/boot".fsType or null == "vfat";
      message = "nixos-bootstrap: the disko layout must mount the EFI system partition (vfat) at /boot.";
    }
  ];

  # Installers work as root. The normal users exist (name, home, UID) before the
  # full config, but have no password or keys: nobody logs in as them until then.
  users.users =
    lib.mapAttrs (_: u: {
      inherit (u) name uid home;
      isNormalUser = true;
    }) (lib.filterAttrs (_: u: u.isNormalUser) mapper.users)
    // {
      root.openssh.authorizedKeys.keys = mapper.rootAuthorizedKeys;
    };

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
      HostKeyAlgorithms = "ssh-ed25519";
    };
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
  };

  # What installers run on the target: they evaluate the config here and
  # author secrets in a git repository (e.g. cloned from GitHub).
  environment.systemPackages = with pkgs; [
    git
    sops
    age
    ssh-to-age
    vim
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
    "pipe-operators"
  ];

  programs.ssh.knownHosts."github.com".publicKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
}
