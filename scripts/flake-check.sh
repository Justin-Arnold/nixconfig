#!/usr/bin/env bash
# Checks this flake the way `nix flake check` would if every host still
# evaluated, without building any host. Runs on the Mac or on workbench,
# from anywhere in the repo.
#
#   scripts/flake-check.sh eval     every NixOS host evaluates, except the legacy ones below
#   scripts/flake-check.sh checks   every checks.<this system> attribute builds
#   scripts/flake-check.sh [all]    both
#
# Prints one line per host or check and a summary, and exits non-zero if
# anything failed. Flakes only see files git knows about, so add new files
# (git add -N is enough) before running it.
set -u

# These no longer evaluate and wait to be fixed or removed. A host that
# breaks and isn't listed here fails the check. pr-previews still pins
# pnpm_9, which nixpkgs dropped in November 2026.
legacy=(checkmk gitea onepassword-connect omada-controller parallels pr-previews)

part=${1:-all}
case $part in eval|checks|all) ;; *) echo "usage: scripts/flake-check.sh [eval|checks|all]" >&2; exit 2 ;; esac

cd "$(git rev-parse --show-toplevel)" || exit 2
untracked=$(git ls-files --others --exclude-standard)
if [[ -n $untracked ]]; then
  echo "warning: the flake can't see these untracked files; git add -N them if they matter:"
  while read -r file; do echo "  $file"; done <<<"$untracked"
fi

failed=()
run() {
  local label=$1 start=$SECONDS out
  shift
  if out=$("$@" 2>&1); then
    printf 'ok    %-40s %ss\n' "$label" "$((SECONDS - start))"
  else
    printf 'FAIL  %-40s %ss\n' "$label" "$((SECONDS - start))"
    # The end of the error is what names the cause.
    tail -n 15 <<<"$out" | sed 's/^/      /'
    failed+=("$label")
  fi
}

if [[ $part != checks ]]; then
  echo "== hosts"
  hosts=$(nix eval --json .#nixosConfigurations --apply builtins.attrNames | tr -d '[]"' | tr ',' ' ') || exit 1
  for host in $hosts; do
    if [[ " ${legacy[*]} " == *" $host "* ]]; then
      printf 'skip  %-40s legacy\n' "$host"
      continue
    fi
    run "$host" nix eval --raw ".#nixosConfigurations.$host.config.system.build.toplevel.drvPath"
  done
fi

if [[ $part != eval ]]; then
  echo "== checks"
  system=$(nix eval --impure --raw --expr builtins.currentSystem) || exit 1
  checks=$(nix eval --json ".#checks.$system" --apply builtins.attrNames | tr -d '[]"' | tr ',' ' ') || exit 1
  for check in $checks; do
    run "$check" nix build --no-link ".#checks.$system.$check"
  done
fi

echo
if (( ${#failed[@]} )); then
  echo "failed: ${failed[*]}"
  exit 1
fi
echo "all passed (darwin and the legacy hosts aren't checked)"
