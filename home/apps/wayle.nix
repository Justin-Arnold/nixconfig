# Wayle took over from hyprpanel when nixpkgs archived it in November 2026.
# It's a whole shell: the bar, notifications, on-screen display and the
# dashboard menu. `wayle panel settings` changes things live, and writes them
# to ~/.config/wayle/runtime.toml, not here; copy anything worth keeping back
# into settings below.
{ ... }:
{
  services.wayle = {
    enable = true;
    settings = {
      general = {
        font-sans = "CaskaydiaCove NF";
        font-mono = "CaskaydiaCove NF";
      };

      bar = {
        background-opacity = 0;
        layout = [
          {
            monitor = "*";
            left = [ "dashboard" "hyprland-workspaces" ];
            center = [ "media" ];
            right = [ "volume" "systray" "notifications" ];
          }
        ];
      };

      modules.hyprland-workspaces.app-icons-show = true;
    };
  };
}
