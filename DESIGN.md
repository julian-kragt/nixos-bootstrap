# Design decisions

Why nixos-bootstrap works the way it does, and what was rejected. How to use it is in [README.md](README.md).

## Install in two steps

The host is installed with a bootstrap system first, and the full config once its secrets are written.

No private key is ever exchanged: the host generates its own SSH key on first boot, and secrets are written directly on
the target, encrypted to that key.

Rejected: generating the host key in advance and copying it with nixos-anywhere's `--extra-files`. It installs in one
step, but each host's private key then exists off the host and has to be generated, stored and transferred.

## Generate the bootstrap system from the full config

Each `<host>-bootstrap` system is generated from `bootstrapEntries.<host>`, whose values usually come from the host's
evaluated full config, so the two can't drift.

`bootstrapEntries` is a separate output with a fixed shape, so nixos-bootstrap doesn't depend on how a config is built.

Rejected: a hand-written bootstrap system per host, which has to be kept in step by hand.

## The config names its hosts

`bootstrapEntries` lists host names literally. Mapping over `self.nixosConfigurations` is infinite recursion, because
that set holds the generated systems, whose names come from `bootstrapEntries`. Naming them also means a broken host
can't block another, and leaves hosts without a disko layout out.

## No inputs of its own

The config passes in its `nixpkgs` and `disko`, so the bootstrap system is built from the same nixpkgs as the full
config, and the evaluated layout is read by the disko that evaluated it. This is why those inputs need exactly those
names, and why there's no `formatter` output.

## Check entries as module options

Every field is required and any other field is an error, with the usual NixOS option error naming the host and field.

Module options default lists and attrsets to empty when they're left out, so a forgotten `users` would silently mean no
users. The `required` helper in `entry-options.nix` removes that default.

## The hardware config must exist

`hardwareConfigPath` must point to an existing file, checked with the entry. The bootstrap system imports that file and
can't be built without it, so an entry naming a missing file isn't valid.

The cost is that nothing in `installerData` can be read until the file exists, including `hardwareConfigPath`. A new
host needs either a stub or a path from the user, as [INSTALL.md](INSTALL.md#2-make-sure-the-hardware-config-exists)
describes.

Rejected: moving the existence check to the import, so the path alone could be read without the file.

## Pass the evaluated disk layout back to disko

`diskoDevices` is usually the evaluated `config.disko.devices`, internal attributes included, and goes into the bootstrap
system as it is. Across disko's example layouts this gives the same disko script as the full config.

This relies on disko accepting its own evaluated output, so a disko change could break it. `tests/run.sh` evaluates it
against the locked disko.

## `installerData` is the output to parse

It holds the checked entry in JSON-safe form, since the evaluated layout contains functions. `disks` comes from the
bootstrap system, so it names the devices of the merged layout that an install wipes.

## Keep the bootstrap system minimal

It's the same for every host, and holds only what the next steps need:

- root SSH with a key, and an ed25519 host key, which is what sops-nix's age recipient derives from;
- the normal users with their name, UID and home, and no password or keys, so per-user work can happen before the full
  config;
- `git`, `sops`, `age`, `ssh-to-age` and `vim`, for writing secrets on the target;
- the `nix-command` and `flakes` features, plus `pipe-operators` so configs using `|>` can be evaluated on the target;
- GitHub's SSH host key, so repositories can be cloned without a prompt.

`system.stateVersion` is the nixpkgs release, because nothing stateful runs on it. The full config sets the host's own.

## Support one way of booting

UEFI with systemd-boot and the EFI system partition at `/boot`, with no static networking or SSH in the initrd. Anything
more needs per-host options, and belongs in the full config.

An assertion rejects any other ESP mountpoint at evaluation, because otherwise it would only fail at the bootloader
install, after the disk is wiped.
