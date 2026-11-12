#!/usr/bin/env bash
# Checks that need no Linux builder: the code is formatted and linted, the example and a
# flake-parts config evaluate, and each broken entry stops evaluation with the message that
# README.md's troubleshooting table lists.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

tool() { nix run --quiet --inputs-from "$root/example" "nixpkgs#$1" -- "${@:2}"; }

nix_eval() {
  nix eval --quiet --no-write-lock-file --override-input nixos-bootstrap "path:$root" "$@"
}

system_of() { echo ".#nixosConfigurations.$1-bootstrap.config.system.build.toplevel.drvPath"; }

pass() { echo "ok    $1"; }

fail() {
  echo "FAIL  $1"
  [ -z "${2:-}" ] || echo "$2" | tail -5
  failures=$((failures + 1))
}

# A copy of a config, outside git, so that it needs no `git add`.
copy() {
  cp -R "$root/$1" "$work/$2"
  echo "$work/$2"
}

expect_evaluates() {
  local name=$1 config=$2 host=$3 dir output
  dir=$(copy "$config" "$name")
  if output=$(cd "$dir" && nix_eval --json ".#installerData.$host" 2>&1 >/dev/null &&
    nix_eval --raw "$(system_of "$host")" 2>&1 >/dev/null); then
    pass "$name"
  else
    fail "$name" "$output"
  fi
}

# name, text the error must contain, sed script that breaks the example
expect_error() {
  local name=$1 expected=$2 edit=$3 dir output
  dir=$(copy example "$name")
  sed -e "$edit" "$root/example/flake.nix" >"$dir/flake.nix"
  # Some errors only come from one of the two, as in an installer's checks.
  output=$(cd "$dir" && {
    nix_eval --json .#installerData.example 2>&1 || true
    nix_eval --raw "$(system_of example)" 2>&1 || true
  })
  if grep -qF -- "$expected" <<<"$output"; then
    pass "$name"
  else
    fail "$name" "$output"
  fi
}

expect_secrets_filtered() {
  local name=secrets-filtered dir data password
  dir=$(copy example "$name")
  sed -e 's/users.users.demo.isNormalUser = true;/users.users.demo = { isNormalUser = true; hashedPassword = "SENTINEL"; };/' \
    "$root/example/flake.nix" >"$dir/flake.nix"
  data=$(cd "$dir" && nix_eval --json .#installerData.example 2>/dev/null)
  password=$(cd "$dir" && nix_eval --json .#nixosConfigurations.example-bootstrap.config.users.users.demo.hashedPassword 2>/dev/null)
  if ! grep -qF SENTINEL <<<"$data" && [ "$password" = null ]; then
    pass "$name"
  else
    fail "$name" "$data $password"
  fi
}

cd "$root"
if tool nixfmt --check $(git ls-files -co --exclude-standard '*.nix') 2>&1; then pass nixfmt; else fail nixfmt; fi
if tool statix check . 2>&1; then pass statix; else fail statix; fi
if tool deadnix --fail . 2>&1; then pass deadnix; else fail deadnix; fi

expect_evaluates example example example
expect_evaluates flake-parts tests/flake-parts myhost
expect_secrets_filtered

not_type='is not of type'
no_value='was accessed but has no value defined'

expect_error no-entries 'has no `bootstrapEntries` output' '/bootstrapEntries =/,/^          };/d'
expect_error recursion 'infinite recursion encountered' \
  's/^          {$/          (self.nixosConfigurations \/\/ {/; s/^          };$/          });/'
expect_error missing-system "example.system' $no_value" '/^ *system = config/d'
expect_error missing-disko "example.diskoDevices' $no_value" '/^ *diskoDevices = /d'
expect_error missing-keys "example.rootAuthorizedKeys' $no_value" '/^ *rootAuthorizedKeys = /d'
expect_error missing-hardware "example.hardwareConfigPath' $no_value" '/^ *hardwareConfigPath = /d'
expect_error missing-users "example.users' $no_value" '/^ *users = config/d'
expect_error unknown-field "example.extra' does not exist" 's/users = config.users.users;/& extra = 1;/'
expect_error hardware-missing "$not_type \`path of an existing file" 's|hardwareConfigPath = .*|hardwareConfigPath = "nope.nix";|'
expect_error hardware-absolute "$not_type \`path of an existing file" 's|hardwareConfigPath = .*|hardwareConfigPath = "/etc/passwd";|'
expect_error hardware-parent "$not_type \`path of an existing file" 's|hardwareConfigPath = .*|hardwareConfigPath = "../flake.nix";|'
expect_error users-list "example.users' $not_type" 's/users = config.users.users;/users = [ "demo" ];/'
expect_error system-darwin "$not_type \`Linux platform" 's/system = config.nixpkgs.hostPlatform.system;/system = "aarch64-darwin";/'
expect_error keys-empty "example.rootAuthorizedKeys' $not_type" 's/rootAuthorizedKeys = .*/rootAuthorizedKeys = [ ];/'
expect_error no-disks 'has no disks.' 's/diskoDevices = config.disko.devices;/diskoDevices = { };/'
expect_error esp-elsewhere 'must mount the EFI system partition (vfat) at /boot' 's|mountpoint = "/boot";|mountpoint = "/boot/efi";|'
expect_error input-renamed 'the config flake has no `disko` input' 's/^    disko = {/    disko2 = {/; s/inputs\.disko\./inputs.disko2./'

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo 'all passed'
