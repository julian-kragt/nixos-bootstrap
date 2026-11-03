# Using nixos-bootstrap in your own installer

This guide is for writing an installer, in any language, that installs NixOS hosts with nixos-bootstrap. To add
nixos-bootstrap to a config and install a host by hand, or to see what the mapper is, start with [README.md](README.md).

Your installer drives the install and owns everything after the first boot. nixos-bootstrap gives it:

- a bootstrap system for any host, ready for nixos-anywhere;
- the host's data as JSON, already checked;
- a target it can log in to as root, with the tools it needs.

The installer needs no knowledge of how a config is organised. The config only has to have the
[mapper](README.md#1-add-the-mapper). The examples are shell, but a program can run the same commands.

## Inputs

An installer needs three things from its user:

| Input | Example |
|---|---|
| The config's flake reference | `git+file:///home/me/nixos-config`, `github:you/nixos-config` |
| The host | `myhost` |
| The target's address | `192.0.2.10` |

Everything else comes from nixos-bootstrap's outputs. Nix commands take the config with `--override-input`:

```sh
bootstrap=github:julian-kragt/nixos-bootstrap
override=(--override-input config "$config")
```

## What you can read

`installerData.<host>` is the only output meant to be parsed. For the example config in this repository:

```sh
nix eval --json "$bootstrap#installerData.$host" "${override[@]}"
```

```json
{
  "hardwareConfigPath": "hardware-configuration.nix",
  "rootAuthorizedKeys": [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIReplaceWithYourOwnPublicKeyReplaceWithYourOw example"
  ],
  "system": "x86_64-linux",
  "users": {
    "demo": {
      "home": "/home/demo",
      "uid": null
    }
  }
}
```

| Field | What it is |
|---|---|
| `system` | the host's platform |
| `rootAuthorizedKeys` | the keys that can log in as root after the install. Check that yours is among them before wiping a disk |
| `hardwareConfigPath` | where the host's hardware config goes, relative to the root of the config |
| `users.<name>.home` | the user's home directory |
| `users.<name>.uid` | the user's UID, or `null` if NixOS allocates it. Then it's only known on the target, once the user exists |

`users` holds normal users only, and has no passwords, keys or packages. It can be empty.

The disk layout isn't in `installerData`, because the evaluated layout holds functions JSON can't print. To show which
disks an install will wipe, read them from the bootstrap system:

```sh
nix eval --json "$bootstrap#nixosConfigurations.$host.config.disko.devices.disk" "${override[@]}" \
  --apply 'builtins.mapAttrs (_: d: d.device)'
```

```json
{"main":"/dev/vda"}
```

## The steps

### 1. Check everything before touching a disk

Run these first, so a broken mapper or bootstrap system fails before anything happens to the target:

```sh
# The hosts that can be installed. Use it to validate the host, or to let the user choose.
nix eval --json "$bootstrap#installerData" "${override[@]}" --apply builtins.attrNames

# The mapper's fields.
data=$(nix eval --json "$bootstrap#installerData.$host" "${override[@]}")

# The disk layout, the hardware config and NixOS's assertions, which installerData doesn't check.
nix eval --raw "$bootstrap#nixosConfigurations.$host.config.system.build.toplevel.drvPath" "${override[@]}"
```

The evaluation only instantiates the system, so it works on macOS as well. The errors name the host and the field, and
are worth showing as they are. What they mean: [troubleshooting](README.md#troubleshooting).

### 2. Make sure the hardware config exists

Reading `installerData.<host>` and evaluating the system both fail if the file at `hardwareConfigPath` doesn't exist, so
the path itself can't be read from `installerData` either. On a new host, the config needs a file before your installer
can start. There are two ways to get the real one, described in
[README step 3](README.md#3-generate-the-hardware-config):

- **Generate it first.** Run `nixos-generate-config --no-filesystems --show-hardware-config` on the booted target, and
  have the user add it to the config. This works with any config reference, but the path can't come from
  `installerData`, as the file doesn't exist yet. It has to come from your user.
- **Generate it during the install.** The user commits a stub, and your installer passes `--generate-hardware-config` to
  nixos-anywhere with `.hardwareConfigPath` from the data. This needs the config as a local `git+file://` checkout, and
  nixos-anywhere has to run from inside it.

### 3. Run nixos-anywhere

nixos-anywhere can't pass `--override-input`, so write a wrapper flake that sets the `config` input:

```sh
tmp=$(mktemp -d)
cat > "$tmp/flake.nix" <<EOF
{
  inputs.nixos-bootstrap.url = "$bootstrap";
  inputs.nixos-bootstrap.inputs.config.url = "$config";
  outputs = { nixos-bootstrap, ... }: { inherit (nixos-bootstrap) nixosConfigurations installerData; };
}
EOF

nix run github:nix-community/nixos-anywhere -- \
  --flake "$tmp#$host" \
  --target-host "root@$target" \
  --build-on remote
```

- The target must already accept root over SSH, as nixos-anywhere requires. Getting there, for example by installing a
  key with a password from the ISO, is up to your installer.
- This wipes the disks in the layout, so ask for confirmation first, showing the disks from above.
- Don't write a lock file for the wrapper. nixos-anywhere evaluates it without one, so every step reads the config as it
  is then, including a newly generated hardware config.
- `--build-on remote` builds on the target, for when the machine running the installer can't build for the target's
  system.
- With `--generate-hardware-config`, add `--generate-hardware-config nixos-generate-config <hardwareConfigPath>` and run
  the command from the root of the config's checkout.
- For a LUKS layout with a `passwordFile`, add `--disk-encryption-keys <passwordFile> <local file with the passphrase>`.

### 4. Wait for the reboot

The target reboots into the bootstrap system.

- It has a new SSH host key, so remove any old `known_hosts` entry for the address. Your installer can't verify the new
  key against anything, so it has to trust it on first use.
- On an encrypted disk, someone has to type the passphrase at the console on every boot, as there's no SSH in the initrd.
  Keep waiting and tell the user, rather than failing on a timeout.

### 5. Do your own work

This is where your installer's own steps go, such as writing secrets. nixos-bootstrap has no opinion on how secrets are
stored, who they're encrypted to, or which keys exist, and it generates no user keys. It gives you these to work with:

- The host key. For sops-nix, this prints its age recipient:
  ```sh
  ssh "root@$target" 'ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub'
  ```
- The users, which exist on the target with their home directories:
  ```sh
  jq -r '.users | keys[]' <<<"$data"
  ```

What the target provides:

- Only root can log in, with one of `rootAuthorizedKeys`. The users have no password or keys, so run things as a user
  with `runuser -u <user> -- <command>` from root.
- `git`, `sops`, `age`, `ssh-to-age` and `vim`.
- nix with the `nix-command`, `flakes` and `pipe-operators` features, so the config can be evaluated on the target.
- GitHub's SSH host key, so repositories can be cloned without a prompt, given credentials.

### 6. Deploy the full config

If the hardware config was generated during the install, it now has to be committed, and pushed if the deploy reads the
config from a remote. Then deploy over the bootstrap system:

```sh
nixos-rebuild switch --flake "$config#$host" \
  --target-host "root@$target" --build-host "root@$target"
```

## Rules for a robust installer

- **Pin nixos-bootstrap** to a tag or commit, `github:julian-kragt/nixos-bootstrap/<tag or commit>`, so an install is
  repeatable and the output format doesn't change underneath you.
- **Read only nixos-bootstrap's outputs**, not the config's `bootstrap` output. Those are checked; the raw one isn't.
- **Remember that `git+file://` only sees tracked files.** A new, untracked hardware config looks like a missing one.
- **Handle reinstalls.** A reinstall wipes the disk and generates a new host key, so the old `known_hosts` entry is wrong,
  and anything encrypted to the old key has to be encrypted to the new one before the full deploy.
- **Don't add steps to the bootstrap system.** It's the same for every host. What a host needs beyond it belongs in the
  full config or in your installer.

## A minimal installer

All the steps together, for a host whose hardware config already exists. It needs nix with flakes and `nixos-rebuild`
on the machine that runs it.

```bash
#!/usr/bin/env bash
# Usage: install-host <config flake ref> <host> <target address>
set -euo pipefail

config=$1 host=$2 target=$3
bootstrap=github:julian-kragt/nixos-bootstrap
override=(--override-input config "$config")

# 1. Check everything before touching a disk.
nix eval --json "$bootstrap#installerData.$host" "${override[@]}" >/dev/null
nix eval --raw "$bootstrap#nixosConfigurations.$host.config.system.build.toplevel.drvPath" "${override[@]}" >/dev/null
disks=$(nix eval --json "$bootstrap#nixosConfigurations.$host.config.disko.devices.disk" "${override[@]}" \
  --apply 'builtins.mapAttrs (_: d: d.device)')

read -r -p "Wipe $disks on $target? Type yes: " answer
[ "$answer" = yes ] || exit 1

# 3. Run nixos-anywhere through a wrapper flake.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/flake.nix" <<EOF
{
  inputs.nixos-bootstrap.url = "$bootstrap";
  inputs.nixos-bootstrap.inputs.config.url = "$config";
  outputs = { nixos-bootstrap, ... }: { inherit (nixos-bootstrap) nixosConfigurations installerData; };
}
EOF
nix run github:nix-community/nixos-anywhere -- \
  --flake "$tmp#$host" --target-host "root@$target" --build-on remote

# 4. Wait for the reboot; the host key is new.
ssh-keygen -R "$target" || true
ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
until ssh "${ssh_opts[@]}" "root@$target" true; do
  echo "Waiting for $target; if its disk is encrypted, type the passphrase at its console."
  sleep 5
done

# 5. Your own work goes here, such as writing secrets to this recipient.
recipient=$(ssh "root@$target" 'ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub')
echo "Host recipient: $recipient"

# 6. Deploy the full config.
nixos-rebuild switch --flake "$config#$host" \
  --target-host "root@$target" --build-host "root@$target"
```
