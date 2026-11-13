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

# The secrets layout: tests/secrets is a secrets repository with both kinds of user file.
# It has no lock file: it gets the example's nixpkgs and this checkout.
nixpkgs_ref=$(nix flake metadata --json "$root/example" |
  tool jq -r '.locks.nodes.nixpkgs.locked | "github:\(.owner)/\(.repo)/\(.rev)"')

secrets_eval() {
  nix eval --quiet --no-write-lock-file --override-input nixos-bootstrap "path:$root" \
    --override-input nixpkgs "$nixpkgs_ref" "$@"
}

# name, text the output must contain, sed script for the flake's secretsEntry, and a
# command run in the copy before evaluating
expect_secrets() {
  local name=secrets-$1 expected=$2 edit=$3 setup=${4:-true} dir output
  dir=$(copy tests/secrets "$name")
  sed -e "$edit" "$root/tests/secrets/flake.nix" >"$dir/flake.nix"
  output=$(cd "$dir" && eval "$setup" && {
    secrets_eval --json .#installerSecretsData 2>&1 || true
    secrets_eval --json .#paths 2>&1 || true
  })
  if grep -qF -- "$expected" <<<"$output"; then
    pass "$name"
  else
    fail "$name" "$output"
  fi
}

per_host='s/"both"/"per-host"/; s|sharedUserPath = .*|sharedUserPath = null;|; s|sharedUserTemplatePath = .*|sharedUserTemplatePath = null;|'
shared='s/"both"/"shared"/; s|hostUserPath = .*|hostUserPath = null;|; s|hostUserTemplatePath = .*|hostUserTemplatePath = null;|'
shared_password='echo "hashedPassword: CHANGEME" >>templates/shared-user.yaml'

expect_secrets both-data '"passwordTemplate":"templates/user.yaml","sharedUserPath":"users"' ''
expect_secrets both '{"home":"users/u.yaml","host":"hosts/h.yaml","hostUser":"host-users/h-u.yaml","password":"host-users/h-u.yaml","sharedUser":"users/u.yaml"}' ''
expect_secrets both-shared-password '"password":"users/u.yaml"' '' \
  "echo 'token: CHANGEME' >templates/user.yaml && $shared_password"
expect_secrets no-password '"password":null' '' "echo 'token: CHANGEME' >templates/user.yaml"
expect_secrets per-host '{"home":"host-users/h-u.yaml","host":"hosts/h.yaml","hostUser":"host-users/h-u.yaml","password":"host-users/h-u.yaml","sharedUser":null}' "$per_host"
expect_secrets shared '{"home":"users/u.yaml","host":"hosts/h.yaml","hostUser":null,"password":"users/u.yaml","sharedUser":"users/u.yaml"}' "$shared" "$shared_password"

dir_type="$not_type \`path of an existing directory"
expect_secrets no-entry 'has no `secretsEntry` output' '/secretsEntry = {/,/^      };/d'
expect_secrets missing-field "secretsEntry.hostPath' $no_value" '/hostPath = /d'
expect_secrets unknown-field "secretsEntry.extra' does not exist" 's/userMode = "both";/& extra = 1;/'
expect_secrets bad-mode "secretsEntry.userMode' $not_type" 's/"both"/"all"/'
expect_secrets path-absolute "$dir_type" 's|hostPath = .*|hostPath = "/etc";|'
expect_secrets path-parent "$dir_type" 's|hostPath = .*|hostPath = "../hosts";|'
expect_secrets path-dot "$dir_type" 's|hostPath = .*|hostPath = "./hosts";|'
expect_secrets path-missing "$dir_type" 's|hostPath = .*|hostPath = "nope";|'
expect_secrets template-missing "$not_type \`path of an existing file" 's|hostTemplatePath = .*|hostTemplatePath = "templates/nope.yaml";|'
expect_secrets path-unused '`sharedUserPath` must be null when userMode is "per-host"' 's/"both"/"per-host"/'
expect_secrets path-required '`hostUserPath` is required when userMode is "both"' 's|hostUserPath = .*|hostUserPath = null;|'
expect_secrets template-required '`sharedUserTemplatePath` is required when userMode is "shared"' \
  's/"both"/"shared"/; s|hostUserPath = .*|hostUserPath = null;|; s|hostUserTemplatePath = .*|hostUserTemplatePath = null;|; s|sharedUserTemplatePath = .*|sharedUserTemplatePath = null;|'
expect_secrets paths-equal 'the directories `host-users` and `host-users` must be different' 's|sharedUserPath = .*|sharedUserPath = "host-users";|'
expect_secrets paths-nested 'the directories `hosts` and `hosts/sub` must be different' 's|sharedUserPath = .*|sharedUserPath = "hosts/sub";|' 'mkdir hosts/sub'
expect_secrets template-inside 'templates must not be inside' 's|hostTemplatePath = .*|hostTemplatePath = "hosts/template.yaml";|' \
  'cp templates/host.yaml hosts/template.yaml'
expect_secrets password-twice 'only one of hostUserTemplatePath and sharedUserTemplatePath' '' "$shared_password"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo 'all passed'
