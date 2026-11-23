# theming

The desktop apps share one color theme, chosen by `systemProfile.theme` in
`modules/common/systemProfile.nix`. It is `"zenwritten-dark"` by default;
`"nord"` is the other choice. Each app maps it to that app's own port of the
theme, so switching is one line and a rebuild. Fonts are separate:
`systemProfile.fonts.primary`.

Zenwritten is the zero-saturation variant of
[Zenbones](https://github.com/zenbones-theme/zenbones.nvim). Where an app
already has a port, it's used as is and pinned by `flake.lock`, and its
app-specific colors stay with that port.

## Switching

Set it on a host, or change the default for all of them:

```nix
systemProfile.theme = "nord";
```

Then rebuild. Apps that are already open pick it up when restarted.

## Where each app's theme comes from

| App | Zenwritten Dark | Nord | Module | Hosts |
|---|---|---|---|---|
| Vicinae | built in (`zenwritten-dark`) | built in (`nord`) | `home/apps/hyprland.nix` | Hyprland desktops |
| Alacritty | Zenbones' own export, `extras/alacritty/zenwritten_dark.toml` in `pkgs.vimPlugins.zenbones-nvim` | `nord` from `pkgs.alacritty-theme` | `home/apps/alacritty.nix` | GUI hosts, incl. Macs |
| VS Code | `rpbritton.zenbones` from the Marketplace (not in nixpkgs), theme `Zenbones Zenwritten Dark` | `arcticicestudio.nord-visual-studio-code`, theme `Nord` | `home/apps/vscode.nix` | GUI hosts, incl. Macs |
| Neovim | `pkgs.vimPlugins.zenbones-nvim` with `lush-nvim`, colorscheme `zenwritten` | `pkgs.vimPlugins.gbprod-nord`, colorscheme `nord` | `home/apps/neovim.nix` | every host |

Both VS Code extensions stay installed, so either can be previewed from the
theme picker. The choice doesn't persist: settings.json is a Home Manager
link.

The VS Code extension is pinned by version and hash. To update it, change
`version`, set `hash = lib.fakeHash`, rebuild, and copy the hash from the
error.

Zen Browser isn't covered yet. It keeps the Nord theme add-on that was
installed by hand.

## Settings saved by the apps

Some apps save a theme picked in their own settings, which could otherwise
win over the one set here.

| App | Where it saves | What happens |
|---|---|---|
| Vicinae | `~/.config/vicinae/settings.json` | The theme set here is loaded through `VICINAE_OVERRIDES` and wins over it on the next start. A theme picked in Vicinae lasts until then. |
| VS Code | nowhere | settings.json is read-only. |
| Neovim, Alacritty | nowhere | |
