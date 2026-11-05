# Used only by the openclaw flake checks: no real SOPS file, and the parts
# that wait on Paperclip and the chat platforms switched on, so the full
# configuration, every assertion and OpenClaw's schema for those parts can be
# evaluated on any machine.
{ lib, ... }:
{
  sops.defaultSopsFile = lib.mkForce "/nonexistent/openclaw.yaml";
  sops.validateSopsFiles = lib.mkForce false;

  openclaw.concierge = {
    withPaperclipKey = lib.mkForce true;
    discordUserId = lib.mkForce "100000000000000001";
    telegramUserId = lib.mkForce "100000001";
  };
}
