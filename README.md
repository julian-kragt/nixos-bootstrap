# nixos-bootstrap

The first NixOS install of a new host: a minimal, generic system that
[nixos-anywhere](https://github.com/nix-community/nixos-anywhere) puts on the disk before your real config can be
deployed. It partitions the disks with your disko layout, boots with your hardware config, and gives root SSH access
plus the tools needed on the target. Nothing else.

You never edit this repository. You add it to your config as an input and add one small output, **`bootstrapEntries`**.
nixos-bootstrap generates the rest.

This guide is for adding it to your nixos-config and installing a host by hand. To drive it from a script or program of
your own (an *installer*, in these docs), see [INSTALL.md](INSTALL.md).

Examples use `myhost` as the host, `192.0.2.10` as the target and `~/nixos-config` as a local checkout of your config.

## Status

nixos-bootstrap is shared as it is, with no compatibility promises: its outputs, including `installerData`, can change.
Your `flake.lock` pins the version you use, so read the changes before you update it.

It evaluates with nixpkgs 24.11 through unstable, and has been installed on x86_64 UEFI hardware. Layouts with LUKS and
`aarch64-linux` hosts evaluate, but haven't been installed yet.

## Why it exists

A full NixOS config that uses [sops-nix](https://github.com/Mic92/sops-nix) depends on a key that a new host doesn't
have yet:

- sops-nix decrypts the host's secrets with a key derived from the host's SSH key, so the secrets have to be encrypted
  to that key.
- With `users.mutableUsers = false` and passwords from sops (`neededForUsers`), installing the full config before
  its secrets can be decrypted leaves every user without a login.

The usual answer is to generate the host key in advance and copy it to the target with nixos-anywhere's
[`--extra-files`](https://github.com/nix-community/nixos-anywhere/blob/main/docs/howtos/secrets.md). That works, and if
you already manage host keys that way you don't need this project. It does mean each host's private key exists
somewhere else first, and has to be generated, stored and transferred.

With nixos-bootstrap, no private key is ever exchanged. The host is installed in two steps: first a bootstrap system,
which needs no secrets and on which the host generates its own key, then the full config, once its secrets have been
written directly on the target. The bootstrap only has to boot and let you in, which is the same for every host, so
there is no hand-written `<host>-bootstrap` system to maintain. It can't drift from the host either, because the
`bootstrapEntries` output takes its values from the host's evaluated full config.

sops-nix is the typical reason, not a requirement. A config without such secrets doesn't strictly need a bootstrap step,
but works the same way. The reasoning behind this and other choices is in [DESIGN.md](DESIGN.md).

## How it works

```
your config flake
─────────────────
nixosConfigurations.<host>                    the full config
        │ evaluated
        ▼
bootstrapEntries.<host>                       one entry per host, which you write
        │
        ▼
nixos-bootstrap: entries.nix checks the fields against entry-options.nix
        │
        ├──────────────────────────────────────────┐
        ▼                                          ▼
nixosConfigurations.<host>-bootstrap       installerData.<host>
        │                                          │
        ▼                                          ▼
nixos-anywhere installs it                 installers read it with
on the target                              nix eval --json
```

A complete install:

1. nixos-anywhere installs your flake's `nixosConfigurations.<host>-bootstrap` on the target and reboots it.
2. The host now has its SSH host key, so you can write its secrets, if it has any.
3. You deploy your full config, `<config>#<host>`, over the bootstrap system.

nixos-bootstrap does step 1. It only makes sure the host is reachable and has what steps 2 and 3 need.

nixos-bootstrap has no inputs of its own: your config passes in its `nixpkgs` and `disko`. The `bootstrapEntries` output
exists so that nixos-bootstrap doesn't depend on how your config is built: organise your config any way you like, only
that output follows a fixed shape.

## Prerequisites

- Your config is a flake with inputs named `nixpkgs` and `disko`. nixos-bootstrap uses them, so the bootstrap system
  is built from the same nixpkgs as your full config, and the evaluated layout is read by the disko that evaluated it.
  It doesn't need flake-parts.
- Each host you want to install is a `nixosConfigurations.<host>` that uses disko for its disks and boots with UEFI,
  with the EFI system partition at `/boot`.
- The machine you install from has nix with flakes. It can be macOS: the target builds its own system.
- The target is booted from a NixOS installer ISO (or another Linux nixos-anywhere can kexec from), reachable over
  SSH as root. The ISO has no root password, so first set one with `sudo passwd root` at its console, or add your key
  to `/root/.ssh/authorized_keys`.
- Your SSH key is in root's `openssh.authorizedKeys.keys` in the host's full config. That list becomes the bootstrap
  system's root keys.

## 1. Add nixos-bootstrap to your config

Add the input, then give the entries in `bootstrapEntries`, one per host that nixos-bootstrap can install. They only read
the evaluated `nixosConfigurations`, so no host module imports them and they can't change your hosts.

In a plain flake, merge the generated systems into your own:

```nix
# flake.nix
inputs.nixos-bootstrap.url = "github:julian-kragt/nixos-bootstrap";

outputs = inputs@{ self, nixpkgs, nixos-bootstrap, ... }: {
  nixosConfigurations = {
    myhost = nixpkgs.lib.nixosSystem { /* ... */ };
  } // nixos-bootstrap.lib.systems inputs;

  installerData = nixos-bootstrap.lib.installerData inputs;

  bootstrapEntries = nixpkgs.lib.mapAttrs (host: { config, ... }: {
    system = config.nixpkgs.hostPlatform.system;
    diskoDevices = config.disko.devices;
    rootAuthorizedKeys = config.users.users.root.openssh.authorizedKeys.keys;
    hardwareConfigPath = "hosts/${host}/hardware-configuration.nix";
    users = config.users.users;
  }) { inherit (self.nixosConfigurations) myhost; };
};
```

With [flake-parts](https://flake.parts), import the module, which adds both generated outputs for you:

```nix
# bootstrap.nix, imported from your mkFlake
{ self, lib, inputs, ... }:
{
  imports = [ inputs.nixos-bootstrap.flakeModules.default ];

  flake.bootstrapEntries = lib.mapAttrs (host: { config, ... }: {
    # the same five fields as above
  }) { inherit (self.nixosConfigurations) myhost; };
}
```

Then run `nix flake lock`. Your `flake.lock` pins the nixos-bootstrap version; `nix flake update nixos-bootstrap` moves it.

Set `hardwareConfigPath` to wherever your config keeps each host's hardware config.

**Name your hosts on the last line.** Only the hosts named there get a bootstrap system, so hosts without a disko layout
stay out by not being listed. Mapping over all of `self.nixosConfigurations` doesn't work: it holds the generated systems,
whose names come from this list, so nix stops with `infinite recursion encountered`. Naming them also keeps host names
from depending on any host's evaluation, so a broken host can't block deploying another.

### The entry's fields

Every entry has exactly these five fields, all required. They are declared as module options in `entry-options.nix`, so
a missing field, an unknown field or a value of the wrong type stops evaluation with the usual NixOS option error, which
names the host and the field.

| Field | Type | Usually | Used for |
|---|---|---|---|
| `system` | a Linux platform, such as `"x86_64-linux"` | `config.nixpkgs.hostPlatform.system` | `nixpkgs.hostPlatform` of the bootstrap system |
| `diskoDevices` | attrset | `config.disko.devices` | partitioning and mounting; its disks' device paths are also in `installerData` as `disks` |
| `rootAuthorizedKeys` | non-empty list of strings | root's keys in the full config, so the same keys work before and after the full deploy. If your full config gives root no keys, list the installing keys here | root's SSH keys on the bootstrap system |
| `hardwareConfigPath` | string, relative to the root of your config; the file must exist | where your full config imports the host's hardware config from | imported into the bootstrap system; `--generate-hardware-config` writes here |
| `users` | attrset, in the shape of `users.users` | `config.users.users` | its normal users are created on the bootstrap system with the same `name`, `uid` and `home`, and no password or keys |

Notes:

- `diskoDevices` may be the evaluated `config.disko.devices`, which goes into the bootstrap system's `disko.devices`
  as it is, along with disko's internal attributes. Plain data, the attrset you would write in
  `disko.devices = { … };`, works too. Disko's own options check the layout.
- `hardwareConfigPath` must point to an existing file, so a host's hardware config is generated before its first
  install (step 2). The bootstrap system imports that file without your config's `specialArgs`, modules or nixpkgs
  settings, so it can only use standard NixOS options.
- `users` is `config.users.users` itself, not a list of names. Each entry needs `isNormalUser`, `uid` and `home`; `name`
  defaults to the attribute's name. Its other options are ignored: passwords, keys and packages in it never reach the
  bootstrap system or `installerData`.

## 2. Generate the hardware config

`hardwareConfigPath` must point to an existing file before nixos-bootstrap evaluates. On a host that has never been
installed, create it in one of two ways.

**a. Before the install, from the booted ISO.** This works with any config reference:

```sh
ssh root@192.0.2.10 nixos-generate-config --no-filesystems --show-hardware-config \
  > hosts/myhost/hardware-configuration.nix
git add hosts/myhost/hardware-configuration.nix
```

Commit and push it too if you install from a pushed config.

**b. In the same nixos-anywhere run**, with `--generate-hardware-config` (step 4). nixos-anywhere writes the file once it
has reached the target, kexec included if it needs one, then runs `git add --intent-to-add` on it, and only then
evaluates the flake. This needs a local checkout of the config, the path inside that checkout, and `git` on your PATH.

The checks in step 3 still need a file until then, so first commit a stub at `hardwareConfigPath`; nixos-anywhere
overwrites it. The stub sets the host's platform, because a real hardware config usually does and the
`bootstrapEntries` output reads it:

```nix
{ nixpkgs.hostPlatform = "x86_64-linux"; }
```

`--no-filesystems` matters: disko defines the filesystems, and a hardware config that defines them too conflicts
with it.

## 3. Check the entry

From your config, this reads the checked entry:

```sh
cd ~/nixos-config
nix eval --json .#installerData.myhost
```

That only checks the entry's fields. Evaluate the bootstrap system too, which checks the disk layout, the hardware
config and NixOS's assertions. It only instantiates the system, so it works on macOS as well:

```sh
nix eval --raw .#nixosConfigurations.myhost-bootstrap.config.system.build.toplevel.drvPath
```

To list the hosts nixos-bootstrap sees:

```sh
nix eval --json .#installerData --apply builtins.attrNames
```

In a git checkout, nix only sees files git tracks, so `git add` new files first.

## 4. Install with nixos-anywhere

This wipes the disks in your disko layout.

```sh
cd ~/nixos-config
nix run github:nix-community/nixos-anywhere -- \
  --flake .#myhost-bootstrap \
  --target-host root@192.0.2.10 \
  --build-on remote \
  --generate-hardware-config nixos-generate-config hosts/myhost/hardware-configuration.nix
```

- Leave out `--generate-hardware-config` if you generated the file in step 2a.
- `--build-on remote` builds on the target. Use it when your machine can't build for the target's system, such as
  from macOS.
- If the disk layout uses LUKS with a `passwordFile` (for example `/tmp/disko-password`), send the passphrase with
  `--disk-encryption-keys /tmp/disko-password <local file holding the passphrase>`.

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

If your machine has no `nixos-rebuild`, such as on macOS, `nix shell nixpkgs#nixos-rebuild-ng` provides it. If your
config is pushed, you can also run it on the target instead, which needs access to your repository from there:

```sh
ssh root@192.0.2.10 nixos-rebuild switch --flake github:you/nixos-config#myhost
```

## Reference

### Outputs

nixos-bootstrap provides these, for your config to use:

| Output | What it is |
|---|---|
| `lib.systems inputs` | the bootstrap systems, as `<host>-bootstrap` |
| `lib.installerData inputs` | the data for installers, by `<host>` |
| `flakeModules.default` | a flake-parts module that adds both to your flake |

They give your config these outputs, one of each for every host in `bootstrapEntries`:

| Output | What it is |
|---|---|
| `nixosConfigurations.<host>-bootstrap` | the bootstrap system for `<host>`, with `<host>` as its hostname; this is what nixos-anywhere installs |
| `installerData.<host>` | `bootstrapEntries.<host>`, checked, with `disks` in place of `diskoDevices`, as JSON-safe data for installers ([INSTALL.md](INSTALL.md#what-you-can-read)) |

`nix flake check` warns about an `unknown flake output` for `bootstrapEntries` and `installerData`. That's harmless.

### The bootstrap system

What it contains:

- the disks from `diskoDevices`, and the hardware config from `hardwareConfigPath`;
- systemd-boot on EFI;
- OpenSSH with only an ed25519 host key (`/etc/ssh/ssh_host_ed25519_key`), which NixOS generates on the target on first
  boot, no passwords, root login with a key from `rootAuthorizedKeys`;
- the normal users from `users`, with the full config's `name`, `uid` and `home`, but without a password or keys, so
  their UIDs and home directories exist before the full config arrives;
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
- `hardwareConfigPath` has to be a NixOS module, so `--generate-hardware-config nixos-facter`, which writes JSON, doesn't
  work.
- Static networking and ZFS's `networking.hostId` aren't carried over. A host that needs them can set them in a
  hand-written hardware config, but `--generate-hardware-config` overwrites that file.
- With a LUKS-encrypted disk, someone types the passphrase at the console on every boot of the bootstrap system: it
  has no SSH in the initrd.
- The bootstrap system is the same for every host. If yours needs something the bootstrap doesn't have, it belongs in
  the full config, deployed after the bootstrap.

### Troubleshooting

| Error | Cause and fix |
|---|---|
| ``nixos-bootstrap: the config flake has no `bootstrapEntries` output`` | The output is missing. Add it (step 1). |
| `infinite recursion encountered` | `bootstrapEntries` takes its host names from `self.nixosConfigurations`. Name the hosts instead (step 1). |
| ``The option `bootstrapEntries.<host>.<field>' was accessed but has no value defined`` | The field is missing. All five are required. |
| ``The option `bootstrapEntries.<host>.<field>' does not exist`` | Only the five fields are allowed. |
| ``A definition for option `bootstrapEntries.<host>.hardwareConfigPath' is not of type `path of an existing file, …'`` | Generate the file (step 2). In a git checkout, untracked files are invisible: `git add` it. The path must be relative to the root of your config. |
| `Path '…' does not exist in Git repository "…"` | Seen when evaluating the full config, or a field read from it: it imports a hardware config that isn't there yet. Generate the file (step 2). |
| `Path '…' in the repository "…" is not tracked by Git` | Seen when evaluating the full config, or a field read from it. In a git checkout, untracked files are invisible: `git add` the file. |
| ``A definition for option `bootstrapEntries.<host>.…' is not of type …`` | Wrong type. `users` takes `config.users.users` itself, not a list of names. `system` must be a Linux platform. `rootAuthorizedKeys` can't be empty. |
| ``nixos-bootstrap: the disko layout of `<host>` has no disks.`` | `diskoDevices` defines no disks. Check that the entry passes the host's `config.disko.devices`. |
| `nixos-bootstrap: the disko layout must mount the EFI system partition (vfat) at /boot.` | The bootstrap system's systemd-boot installs to `/boot`. Change the layout's ESP mountpoint. |
| `called without required argument 'nixpkgs'` or `'disko'` | nixos-bootstrap uses your config's `nixpkgs` and `disko` inputs: your flake needs inputs with exactly those names. |

### Repository layout

```
flake.nix                         `lib` and `flakeModules`, wiring the files below together
entries.nix                       the config's `bootstrapEntries`, checked against entry-options.nix
entry-options.nix                 an entry's fields, as module options
installer-data.nix                builds `installerData`
nixos-configurations.nix          builds the bootstrap systems
bootstrap.nix                     the bootstrap system's NixOS module
example/flake.nix                 a plain flake using nixos-bootstrap: one QEMU host and its entry
example/hardware-configuration.nix
tests/                            the checks CI runs: errors, the example and a flake-parts config
DESIGN.md                         why it works the way it does
```

To try it with the example config, from a checkout of this repository:

```sh
cd example
nix eval --json .#installerData.example
nix eval --raw .#nixosConfigurations.example-bootstrap.config.system.build.toplevel.drvPath
```

To run the tests, which need nix with flakes: `tests/run.sh`.

## License

[MIT](LICENSE).
