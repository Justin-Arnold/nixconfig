{ pkgs, ... }:

{
  system.activationScripts.postActivation.text = ''
    # Ensure .ssh directory exists with correct permissions
    mkdir -p /Users/justin/.ssh
    chmod 700 /Users/justin/.ssh

    # Generate ed25519 key if it doesn't exist
    if [ ! -f /Users/justin/.ssh/id_ed25519 ]; then
      ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f /Users/justin/.ssh/id_ed25519 -C "hello@justin-arnold.com" -N ""
    fi

    # Set correct permissions
    chmod 600 /Users/justin/.ssh/id_ed25519
    chmod 644 /Users/justin/.ssh/id_ed25519.pub
    chown -R justin /Users/justin/.ssh
  '';
}