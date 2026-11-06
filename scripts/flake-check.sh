#!/usr/bin/env bash
# Checks this flake the way `nix flake check` would if every host still
# evaluated, without building any host. Runs on the Mac, on workbench and in
# CI, from anywhere in the repo.
#
#   scripts/flake-check.sh eval [host...]     every NixOS host evaluates, except the legacy ones below
#   scripts/flake-check.sh checks [check...]  every checks.<this system> attribute builds
#   scripts/flake-check.sh darwin [host...]   every nix-darwin host evaluates
#   scripts/flake-check.sh [all]              eval and checks, and darwin on a Mac
#
# Names after a part check only those, e.g. `eval agents desktop` or
# `checks jev-mcp`; a legacy host named this way is evaluated too.
#
# Prints one line per host or check and a summary, and exits non-zero if
# anything failed. Flakes only see files git knows about, so add new files
# (git add -N is enough) before running it.
set -u

# These no longer evaluate and wait to be fixed or removed. A host that
# breaks and isn't listed here fails the check. pr-previews still pins
# pnpm_9, which nixpkgs dropped in November 2026.
legacy=(checkmk gitea onepassword-connect omada-controller parallels pr-previews)

usage="usage: scripts/flake-check.sh [eval|checks|darwin [name...] | all]"
part=${1:-all}
shift $(( $# > 0 ))
names=("$@")
case $part in
  eval|checks|darwin) ;;
  all) (( ${#names[@]} == 0 )) || { echo "$usage" >&2; exit 2; } ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
parts=("$part")
if [[ $part == all ]]; then
  parts=(eval checks)
  [[ $(uname -s) == Darwin ]] && parts+=(darwin)
fi
has() { [[ " ${parts[*]} " == *" $1 "* ]]; }

cd "$(git rev-parse --show-toplevel)" || exit 2
untracked=$(git ls-files --others --exclude-standard)
if [[ -n $untracked ]]; then
  echo "warning: the flake can't see these untracked files; git add -N them if they matter:"
  while read -r file; do echo "  $file"; done <<<"$untracked"
fi

# In CI there's no running it again by hand, so a failure prints more.
tail_lines=15
[[ ${CI:-} == true ]] && tail_lines=200

failed=()
run() {
  local label=$1 start=$SECONDS out
  shift
  if out=$("$@" 2>&1); then
    printf 'ok    %-40s %ss\n' "$label" "$((SECONDS - start))"
  else
    printf 'FAIL  %-40s %ss\n' "$label" "$((SECONDS - start))"
    # The end of the error is what names the cause.
    tail -n "$tail_lines" <<<"$out" | sed 's/^/      /'
    failed+=("$label")
  fi
}

# The attribute names under one of the flake's outputs, or the names given
# if they're all there.
pick() {
  local output=$1 all name
  all=$(nix eval --json "$output" --apply builtins.attrNames | tr -d '[]"' | tr ',' ' ') || return 1
  if (( ${#names[@]} == 0 )); then
    echo "$all"
    return
  fi
  for name in "${names[@]}"; do
    if [[ " $all " != *" $name "* ]]; then
      echo "no $name in $output; there's: $all" >&2
      return 1
    fi
  done
  echo "${names[*]}"
}

if has eval; then
  echo "== hosts"
  hosts=$(pick .#nixosConfigurations) || exit 2
  for host in $hosts; do
    if (( ${#names[@]} == 0 )) && [[ " ${legacy[*]} " == *" $host "* ]]; then
      printf 'skip  %-40s legacy\n' "$host"
      continue
    fi
    run "$host" nix eval --raw ".#nixosConfigurations.$host.config.system.build.toplevel.drvPath"
  done
fi

if has darwin; then
  echo "== darwin"
  hosts=$(pick .#darwinConfigurations) || exit 2
  for host in $hosts; do
    run "$host" nix eval --raw ".#darwinConfigurations.$host.system.drvPath"
  done
fi

if has checks; then
  echo "== checks"
  system=$(nix eval --impure --raw --expr builtins.currentSystem) || exit 2
  checks=$(pick ".#checks.$system") || exit 2
  for check in $checks; do
    run "$check" nix build --no-link ".#checks.$system.$check"
  done
fi

echo
if (( ${#failed[@]} )); then
  echo "failed: ${failed[*]}"
  exit 1
fi
skipped=()
[[ $part == all ]] && ! has darwin && skipped+=(darwin)
has eval && (( ${#names[@]} == 0 )) && skipped+=("the legacy hosts")
if (( ${#skipped[@]} )); then
  note=$(printf '%s, ' "${skipped[@]}")
  echo "all passed (not checked: ${note%, })"
else
  echo "all passed"
fi
