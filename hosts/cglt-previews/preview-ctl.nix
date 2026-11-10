# preview-ctl: what sshd runs for every connection on the deploy port
# (ForceCommand, deploy.nix). It's deliberately generic. Everything about
# previews lives in the monorepo's previews/scripts/host.sh, which the job
# sends along, so this rarely needs to change.
#
#   tar -czf - <files> | ssh -p <port> preview-deploy@<host> <verb> [arg...]
#
# 1. The client's words (SSH_ORIGINAL_COMMAND) are split on whitespace,
#    without globbing. Each must match ^[A-Za-z0-9._:/=@+-]+$, and there must
#    be at least one, or it exits 2.
# 2. stdin, a gzip'd tar stream, is unpacked into a fresh
#    <workRoot>/job.XXXXXX. If it isn't one, or previews/scripts/host.sh isn't
#    in it, it exits 2.
# 3. From that directory it runs `bash previews/scripts/host.sh <words>` in a
#    clean environment: PATH (below), HOME, USER, SSH_AUTH_SOCK and every
#    PREVIEW_* variable the client sent, with umask 0022. stdout and stderr
#    go straight back to the client.
# 4. It removes the work directory and exits with host.sh's status.
#
# host.sh is arbitrary code from the pull request, and preview-deploy is root
# through the docker group. This script checks the shape of the request and
# nothing else (docs/cglt-previews/REFERENCE.md, "How GitHub Actions reaches
# the host").
{ lib, writeShellApplication, bash, coreutils, gnutar, gzip,
  # Everything host.sh gets on its PATH.
  tools,
  # Where the job directories go. Must exist and be writable by the user.
  workRoot,
  # Appended to PATH, for sudo.
  wrappers ? "/run/wrappers/bin",
}:
let
  path = lib.concatStringsSep ":" (lib.filter (p: p != "") [ (lib.makeBinPath tools) wrappers ]);
in
writeShellApplication {
  name = "preview-ctl";
  runtimeInputs = [ coreutils gnutar gzip ];
  text = ''
    # Bracket ranges in the pattern below mean ASCII only.
    LC_ALL=C
    set -o noglob
    # Files jobs write under /srv/previews are read by File Browser and the
    # containers too.
    umask 0022

    die() {
      echo "preview-ctl: $*" >&2
      exit 2
    }

    request=''${SSH_ORIGINAL_COMMAND:-}
    [[ $request != *$'\n'* ]] || die "the command must be a single line"
    read -ra args <<<"$request"
    (( ''${#args[@]} > 0 )) || die "usage: ssh ... <verb> [arg...], with a gzip'd tar stream on stdin"
    for arg in "''${args[@]}"; do
      [[ $arg =~ ^[A-Za-z0-9._:/=@+-]+$ ]] ||
        die "refused argument $(printf '%q' "$arg"): only letters, digits and ._:/=@+- are allowed"
    done

    work=$(mktemp -d "${workRoot}/job.XXXXXX")
    # Containers may leave root-owned files behind; the work directory's
    # tmpfiles age rule removes whatever this can't.
    trap 'cd / && rm -rf "$work" 2>/dev/null || true' EXIT

    tar -xzf - -C "$work" --no-same-owner ||
      die "stdin must be a gzip'd tar stream"
    [[ -f $work/previews/scripts/host.sh ]] ||
      die "previews/scripts/host.sh isn't in the tar stream"

    environment=(
      "PATH=${path}"
      "HOME=''${HOME:-/}"
      "USER=''${USER:-$(id -un)}"
    )
    if [[ -n ''${SSH_AUTH_SOCK:-} ]]; then
      environment+=("SSH_AUTH_SOCK=$SSH_AUTH_SOCK")
    fi
    for name in "''${!PREVIEW_@}"; do
      environment+=("$name=''${!name}")
    done

    cd "$work"
    status=0
    env -i "''${environment[@]}" ${lib.getExe bash} previews/scripts/host.sh "''${args[@]}" || status=$?
    exit "$status"
  '';
}
