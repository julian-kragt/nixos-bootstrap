# nixos-bootstrap

The first NixOS install of a new host: a minimal, generic system that
[nixos-anywhere](https://github.com/nix-community/nixos-anywhere) puts on the disk before your real config can be
deployed. It partitions the disks with your disko layout, boots with your hardware config, and gives root SSH access
plus the tools needed on the target. Nothing else.

You never edit this repository. You add one small output to your config, the **mapper**, and pass your config to
nixos-bootstrap as a parameter.

This guide is for adding it to your nixos-config and installing a host by hand. To drive it from a script or program of
your own, see [INSTALL.md](INSTALL.md).

Examples use `myhost` as the host, `192.0.2.10` as the target and `~/nixos-config` as a local checkout of your config.

## Why it exists

A full NixOS config that uses [sops-nix](https://github.com/Mic92/sops-nix) can't be the first thing on a new host:

- sops-nix decrypts the host's secrets with a key derived from the host's SSH key. That key is generated on the
  first boot, so before the install there is nothing to encrypt the secrets to.
- With `users.mutableUsers = false` and passwords from sops (`neededForUsers`), installing the full config before
  its secrets can be decrypted leaves every user without a login.

So the host is installed in two steps: first a bootstrap system, which needs no secrets, then the full config once the
host runs and has its host key. The bootstrap only has to boot and let you in, which is the same for every host, so
there is no hand-written `<host>-bootstrap` system to maintain. It can't drift from the host either, because the mapper
takes its values from the host's evaluated full config.

sops-nix is the typical reason, not a requirement. A config without such secrets doesn't strictly need a bootstrap step,
but works the same way.

## How it works

```
your config flake                          nixos-bootstrap
─────────────────                          ───────────────
nixosConfigurations.<host>                 input `config`  =  your config flake
  (the full config)                              │
        │ evaluated                              ▼
        ▼                                  entries.nix: check the fields
bootstrap.<host>  ───────────────────────▶ against entry-options.nix
  (the mapper)                                   │
                                   ┌─────────────┴──────────────┐
                                   ▼                            ▼
                         nixosConfigurations.<host>    installerData.<host>
                                   │                            │
                                   ▼                            ▼
                         nixos-anywhere installs it     installers read it with
                         on the target                  nix eval --json
```

A complete install:

1. nixos-anywhere installs nixos-bootstrap's `nixosConfigurations.<host>` on the target and reboots it.
2. The host now has its SSH host key, so you can write its secrets, if it has any.
3. You deploy your full config, `<config>#<host>`, over the bootstrap system.

nixos-bootstrap does step 1. It only makes sure the host is reachable and has what steps 2 and 3 need.

The config is a flake input because flakes take no arguments: an input is the only way to give a flake something from
outside. The input is named `config` and points to a small example by default. The mapper exists so that nixos-bootstrap
doesn't depend on how your config is built: organise your config any way you like, only the mapper follows a fixed shape.

## Prerequisites

- Your config is a flake with inputs named `nixpkgs` and `disko`. nixos-bootstrap follows them, so the bootstrap system
  is built from the same nixpkgs as your full config, and the evaluated layout is read by the disko that evaluated it.
- Each host you want to install is a `nixosConfigurations.<host>` that uses disko for its disks and boots with UEFI,
  with the EFI system partition at `/boot`.
- The machine you install from has nix with flakes. It can be macOS: the target builds its own system.
- The target is booted from a NixOS installer ISO (or another Linux nixos-anywhere can kexec from), reachable over
  SSH as root.
- Your SSH key is in root's `openssh.authorizedKeys.keys` in the host's full config. That list becomes the bootstrap
  system's root keys.

## 1. Add the mapper

The mapper is an output named `bootstrap`, with one entry per host that nixos-bootstrap can install. It only reads the
evaluated `nixosConfigurations`, so no host module imports it and it can't change your hosts.

```nix
# flake.nix
outputs = { self, nixpkgs, disko, ... }: {
  nixosConfigurations.myhost = nixpkgs.lib.nixosSystem { /* ... */ };

  bootstrap = nixpkgs.lib.mapAttrs (host: { config, ... }: {
    system = config.nixpkgs.hostPlatform.system;
    diskoDevices = config.disko.devices;
    rootAuthorizedKeys = config.users.users.root.openssh.authorizedKeys.keys;
    hardwareConfigPath = "hosts/${host}/hardware-configuration.nix";
    users = config.users.users;
  }) self.nixosConfigurations;
};
```

Set `hardwareConfigPath` to wherever your config keeps each host's hardware config. If some of your hosts have no disko
layout, leave them out by replacing `self.nixosConfigurations` with:

```nix
nixpkgs.lib.filterAttrs (_: c: c.config ? disko && c.config.disko.devices.disk != { }) self.nixosConfigurations
```

With [flake-parts](https://flake.parts), the same thing as a module:

```nix
# flake.nix
outputs = inputs@{ flake-parts, ... }:
  flake-parts.lib.mkFlake { inherit inputs; } {
    imports = [
      # ...
      ./bootstrap.nix
    ];
  };
```

```nix
# bootstrap.nix
{ self, lib, ... }:
{
  flake.bootstrap = lib.mapAttrs (host: { config, ... }: {
    # the same five fields as above
  }) self.nixosConfigurations;
}
```

### The mapper's fields

Every entry has exactly these five fields, all required. They are declared as module options in `entry-options.nix`, so
a missing field, an unknown field or a value of the wrong type stops evaluation with the usual NixOS option error, which
names the host and the field.

| Field | Type | Usually | Used for |
|---|---|---|---|
| `system` | a Linux platform, such as `"x86_64-linux"` | `config.nixpkgs.hostPlatform.system` | `nixpkgs.hostPlatform` of the bootstrap system |
| `diskoDevices` | attrset | `config.disko.devices` | partitioning and mounting; its disks' device paths are also in `installerData` as `disks` |
| `rootAuthorizedKeys` | non-empty list of strings | root's keys in the full config, so the same keys work before and after the full deploy. If your full config gives root no keys, list the installing keys here | root's SSH keys on the bootstrap system |
| `hardwareConfigPath` | string, relative to the root of your config; the file must exist | where your full config imports the host's hardware config from | imported into the bootstrap system; `--generate-hardware-config` writes here |
| `users` | attrset, in the shape of `users.users` | `config.users.users` | its normal users are created on the bootstrap system with the same `uid` and `home`, and no password or keys |

Notes:

- `diskoDevices` may be the evaluated `config.disko.devices`, which goes into the bootstrap system's `disko.devices`
  as it is, along with disko's internal attributes. Plain data, the attrset you would write in
  `disko.devices = { … };`, works too. Disko's own options check the layout.
- `hardwareConfigPath` must point to an existing file, so a host's hardware config is generated before its first
  install (step 3). The bootstrap system imports that file without your config's `specialArgs`, modules or nixpkgs
  settings, so it can only use standard NixOS options.
- `users` is `config.users.users` itself, not a list of names. Each entry needs `isNormalUser`, `uid` and `home`, and its
  other options are ignored: passwords, keys and packages in it never reach the bootstrap system or `installerData`.

## 2. Check the mapper

On nix commands, `--override-input` replaces the `config` input with your flake. This reads the checked entry:

```sh
cd ~/nixos-config
nix eval --json github:julian-kragt/nixos-bootstrap#installerData.myhost \
  --override-input config "git+file://$PWD"
```

That only checks the mapper's fields. Evaluate the bootstrap system too, which checks the disk layout, the hardware
config and NixOS's assertions. It only instantiates the system, so it works on macOS as well:

```sh
nix eval --raw github:julian-kragt/nixos-bootstrap#nixosConfigurations.myhost.config.system.build.toplevel.drvPath \
  --override-input config "git+file://$PWD"
```

To list the hosts nixos-bootstrap sees:

```sh
nix eval --json github:julian-kragt/nixos-bootstrap#installerData \
  --override-input config "git+file://$PWD" --apply builtins.attrNames
```

Any flake reference works for `config`: `git+file://` for a local checkout, `github:` or `git+ssh://` for a pushed
config. A `git+file://` reference only sees files git tracks, so `git add` new files first. `path:` sees everything in
the directory, untracked files included.

On a new host the first two checks fail until the hardware config exists, which is the next step.

## 3. Generate the hardware config

`hardwareConfigPath` must point to an existing file before nixos-bootstrap evaluates. On a host that has never been
installed, create it in one of two ways.

**a. Before the install, from the booted ISO.** This works with any config reference:

```sh
ssh root@192.0.2.10 nixos-generate-config --no-filesystems --show-hardware-config \
  > hosts/myhost/hardware-configuration.nix
git add hosts/myhost/hardware-configuration.nix
```

Commit and push it too if you pass the config as `github:` or `git+ssh://`.

**b. In the same nixos-anywhere run**, with `--generate-hardware-config` (step 4). nixos-anywhere writes the file after it
has booted its installer on the target, then runs `git add --intent-to-add` on it, and only then evaluates the flake.
This needs the config as a local `git+file://` checkout, the path inside that checkout, and `git` on your PATH.

The checks in step 2 still need a file until then, so first commit a stub at `hardwareConfigPath`; nixos-anywhere
overwrites it. The stub sets the host's platform, because a real hardware config usually does and the mapper reads it:

```nix
{ nixpkgs.hostPlatform = "x86_64-linux"; }
```

`--no-filesystems` matters: disko defines the filesystems, and a hardware config that defines them too conflicts
with it.

## 4. Install with nixos-anywhere

This wipes the disks in your disko layout.

nixos-anywhere has no way to pass `--override-input` to the nix commands it runs, so give it a wrapper flake that sets the
`config` input:

```sh
config="git+file://$HOME/nixos-config"
host=myhost
tmp=$(mktemp -d)
cat > "$tmp/flake.nix" <<EOF
{
  inputs.nixos-bootstrap.url = "github:julian-kragt/nixos-bootstrap";
  inputs.nixos-bootstrap.inputs.config.url = "$config";
  outputs = { nixos-bootstrap, ... }: { inherit (nixos-bootstrap) nixosConfigurations; };
}
EOF

cd ~/nixos-config
nix run github:nix-community/nixos-anywhere -- \
  --flake "$tmp#$host" \
  --target-host root@192.0.2.10 \
  --build-on remote \
  --generate-hardware-config nixos-generate-config "hosts/$host/hardware-configuration.nix"
```

- Leave out `--generate-hardware-config` if you generated the file in step 3a.
- `--build-on remote` builds on the target. Use it when your machine can't build for the target's system, such as
  from macOS.
- If the disk layout uses LUKS with a `passwordFile` (for example `/tmp/disko-password`), send the passphrase with
  `--disk-encryption-keys /tmp/disko-password <local file holding the passphrase>`.
- Don't run `nix flake lock` on the wrapper. nixos-anywhere evaluates it without a lock file, so every step reads
  your checkout as it is then, including the newly generated hardware config.
- For repeatable installs, pin nixos-bootstrap: `github:julian-kragt/nixos-bootstrap/<tag or commit>`.

After the reboot, type the LUKS passphrase at the console if the disk is encrypted. Then root can log in over SSH
with one of `rootAuthorizedKeys`. The host has a new SSH host key, so remove an old `known_hosts` entry for its
address if you reinstalled it.

## 5. Deploy your full config

Commit the hardware config, if it was generated in this run.

If your config has secrets, write them now. How is up to you; the bootstrap system gives you:

- the host's SSH key, at `/etc/ssh/ssh_host_ed25519_key`. For sops-nix, this prints its age recipient:
  ```sh
  ssh root@192.0.2.10 'ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub'
  ```
- the normal users from `users`, with their home directories, for anything per-user;
- `sops`, `age`, `ssh-to-age` and `git` on the target.

Then deploy the full config over the bootstrap system:

```sh
nixos-rebuild switch --flake ~/nixos-config#myhost \
  --target-host root@192.0.2.10 --build-host root@192.0.2.10
```

If your machine has no `nixos-rebuild` and your config is pushed, run it on the target instead, which needs access to
your repository from there:

```sh
ssh root@192.0.2.10 nixos-rebuild switch --flake github:you/nixos-config#myhost
```

## Reference

### Outputs

| Output | What it is |
|---|---|
| `nixosConfigurations.<host>` | the bootstrap system for `<host>`; this is what nixos-anywhere installs |
| `installerData.<host>` | `bootstrap.<host>` of your config, checked, with `disks` in place of `diskoDevices`, as JSON-safe data for installers ([INSTALL.md](INSTALL.md#what-you-can-read)) |

There is one of each for every host in your config's `bootstrap` output.

### The bootstrap system

What it contains:

- the disks from `diskoDevices`, and the hardware config from `hardwareConfigPath`;
- systemd-boot on EFI;
- OpenSSH with only an ed25519 host key (`/etc/ssh/ssh_host_ed25519_key`), which NixOS generates on the target on first
  boot, no passwords, root login with a key from `rootAuthorizedKeys`;
- the normal users from `users`, with the full config's `uid` and `home`, but without a password or keys, so their
  UIDs and home directories exist before the full config arrives;
- `git`, `sops`, `age`, `ssh-to-age` and `vim`, nix with the `nix-command`, `flakes` and `pipe-operators` features,
  and GitHub's SSH host key, so you can clone repositories and evaluate your config on the target.

What it leaves to the full config: Home Manager, sops-nix, passwords, user SSH keys, services, and the host's own
`system.stateVersion` (the bootstrap uses the nixpkgs release; nothing stateful runs on it). It doesn't generate user
keys of any kind.

### Requirements and limits

- The host uses disko, and boots with UEFI (systemd-boot), with the EFI system partition at `/boot`. Evaluation fails
  with any other layout. BIOS boot isn't supported.
- Only root can log in to the bootstrap system.
- A user's primary group isn't carried over from the full config.
- Static networking and ZFS's `networking.hostId` aren't carried over. A host that needs them can set them in a
  hand-written hardware config, but `--generate-hardware-config` overwrites that file.
- With a LUKS-encrypted disk, someone types the passphrase at the console on every boot of the bootstrap system: it
  has no SSH in the initrd.
- The bootstrap system is the same for every host. If yours needs something the bootstrap doesn't have, it belongs in
  the full config, deployed after the bootstrap.

### Troubleshooting

| Error | Cause and fix |
|---|---|
| ``nixos-bootstrap: the config flake has no `bootstrap` output`` | The mapper is missing, or `config` points to the wrong flake. Add the mapper (step 1). |
| ``The option `bootstrap.<host>.<field>' was accessed but has no value defined`` | The field is missing. All five are required. |
| ``The option `bootstrap.<host>.<field>' does not exist`` | Only the five fields are allowed. |
| ``A definition for option `bootstrap.<host>.hardwareConfigPath' is not of type `path of an existing file, …'`` | Generate the file (step 3). With `git+file://`, untracked files are invisible: `git add` it. The path must be relative to the root of your config. |
| `path '…/hardware-configuration.nix' does not exist` | Your full config imports a hardware config that isn't there yet. Generate the file (step 3). |
| `Path '…' in the repository "…" is not tracked by Git` | With `git+file://`, untracked files are invisible: `git add` the file. |
| ``A definition for option `bootstrap.<host>.…' is not of type …`` | Wrong type. `users` takes `config.users.users` itself, not a list of names. `system` must be a Linux platform. `rootAuthorizedKeys` can't be empty. |
| ``nixos-bootstrap: the disko layout of `<host>` has no disks.`` | `diskoDevices` defines no disks. Check that the mapper passes the host's `config.disko.devices`. |
| `nixos-bootstrap: the disko layout must mount the EFI system partition (vfat) at /boot.` | The bootstrap system's systemd-boot installs to `/boot`. Change the layout's ESP mountpoint. |
| An error about input `config/nixpkgs` or `config/disko` | nixos-bootstrap follows your config's `nixpkgs` and `disko` inputs: your flake needs inputs with exactly those names. |

### Repository layout

```
flake.nix                         inputs (`config` is the parameter), wires the files below into outputs
entries.nix                       the config's mapper entries, checked against entry-options.nix
entry-options.nix                 the mapper's fields, as module options
installer-data.nix                the `installerData` output
nixos-configurations.nix          the `nixosConfigurations` output
bootstrap.nix                     the bootstrap system's NixOS module
example/flake.nix                 the default `config`: one QEMU host and its mapper
example/hardware-configuration.nix
```

To try it with the example config, from a checkout of this repository:

```sh
nix eval --json .#installerData.example
nix eval --raw .#nixosConfigurations.example.config.system.build.toplevel.drvPath
```
