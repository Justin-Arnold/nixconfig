# theming

The desktop apps share one color theme, chosen by `systemProfile.theme` in
`modules/common/systemProfile.nix`. It is `"zenwritten-dark"` by default;
`"nord"` and `"gneiss"` are the other choices. Each app maps it to that
app's own port of the theme, so switching is one line and a rebuild. Fonts
are separate: `systemProfile.fonts.primary`.

Zenwritten is the zero-saturation variant of
[Zenbones](https://github.com/zenbones-theme/zenbones.nvim). Where an app
already has a port of Zenwritten or Nord, it's used as is and pinned by
`flake.lock`, and its app-specific colors stay with that port. Gneiss is
this repo's own theme, below.

## Gneiss

Gneiss (pronounced "nice") is Nord's colors on neutral dark grays. It
started as a copy of Nord's values and is maintained here on its own, so a
change to Nord doesn't change it. Everything is in
`modules/common/themes/gneiss/`:

- `palette.toml`: the base colors, `gneiss0` to `gneiss15` and
  `gneiss-comment`, numbered like Nord's, and the shared roles. The four
  background grays keep Nord's steps between its own (1.24, 1.45 and 1.69
  to 1 against the background); the text and accent colors are Nord's.
- `vscode/`: the extension. `themes/gneiss-color-theme.json` began as
  Nord's VS Code theme with each Nord color replaced by the Gneiss color in
  its place, written as `{{gneiss0}}` and so on.
- `neovim.lua`: the colorscheme. It began as the highlights that
  [nord.nvim](https://github.com/gbprod/nord.nvim) sets with its default
  options, Nord's colors replaced the same way.
- `alacritty.toml` and `vicinae.toml`: the terminal colors and the launcher
  theme, the same way. The Vicinae theme follows the Nord theme Vicinae
  ships, with the accent the rest of the desktop uses (`gneiss8`).
- `default.nix`: builds them all, filling in the colors from
  `palette.toml`. It fails if a template names a color that isn't one of
  the base colors.
- `NOTICE`: the licenses of the two ports forked from Nord's, VS Code's
  (MIT) and nord.nvim (WTFPL).

Two changes from Nord so far: every terminal (Alacritty, VS Code's,
Neovim's) uses the comment gray for bright black, where Nord uses its border
gray (1.7:1, too faint to read), and the grays are neutral.

## Switching

Set it on a host, or change the default for all of them:

```nix
systemProfile.theme = "nord";
```

Then rebuild. Apps that are already open pick it up when restarted.

## Where each app's theme comes from

| App | Zenwritten Dark | Nord | Gneiss | Module | Hosts |
|---|---|---|---|---|---|
| Vicinae | built in (`zenwritten-dark`) | built in (`nord`) | Gneiss's `vicinae.toml`, installed as `gneiss` | `home/apps/hyprland.nix` | Hyprland desktops |
| Alacritty | Zenbones' own export, `extras/alacritty/zenwritten_dark.toml` in `pkgs.vimPlugins.zenbones-nvim` | `nord` from `pkgs.alacritty-theme` | Gneiss's `alacritty.toml` | `home/apps/alacritty.nix` | GUI hosts, incl. Macs |
| VS Code | `rpbritton.zenbones` from the Marketplace (not in nixpkgs), theme `Zenbones Zenwritten Dark` | `arcticicestudio.nord-visual-studio-code`, theme `Nord` | Gneiss's extension, theme `Gneiss` | `home/apps/vscode.nix` | GUI hosts, incl. Macs |
| Neovim | `pkgs.vimPlugins.zenbones-nvim` with `lush-nvim`, colorscheme `zenwritten` | `pkgs.vimPlugins.gbprod-nord`, colorscheme `nord` | Gneiss's plugin, colorscheme `gneiss` | `home/apps/neovim.nix` | every host |
| Wayle | the palette, plus a `zenwritten-dark` theme file so it's listed in Wayle's settings | the palette (Wayle's own Nord values) | the palette, plus a `gneiss` theme file | `home/apps/wayle.nix` | Hyprland desktops |
| Hyprland borders | the palette: `accent` for the focused window, `border` for the rest | the palette | the palette | `home/apps/hyprland.nix`, `home/dotfiles/hyprland/init.lua` | Hyprland desktops |
| hy3 tab bars | the palette: `accent` for the focused tab, grays for the others, `red` urgent, `yellow` locked | the palette | the palette | `home/dotfiles/hyprland/config/layout.lua` | Hyprland desktops |
| hyprshell switcher | the palette, as its CSS variables | the palette | the palette | `home/apps/hyprshell.nix` | NixOS GUI hosts |
| lazygit | the palette, as `gui.theme`; diffs use the terminal's colors | the palette | the palette | `home/apps/lazygit.nix` | every host |

All three VS Code extensions stay installed, so any of them can be previewed
from the theme picker. The choice doesn't persist: settings.json is a Home
Manager link.

The VS Code extension is pinned by version and hash. To update it, change
`version`, set `hash = lib.fakeHash`, rebuild, and copy the hash from the
error.

Zen Browser isn't covered yet. It keeps the Nord theme add-on that was
installed by hand.

## The palette

Apps with no port of the theme, or none that can be picked by name from
their config, are themed from raw colors: `systemProfile.palette`, the
`[colors]` table of `modules/common/themes/<theme>.toml`, or of
`<theme>/palette.toml` for Gneiss. Each file gives every color a role,
such as `bg`, `surface`, `fg-muted`, `accent` or `red`, with a comment on
where it comes from and what it's for; a role can name one of the file's
`[base]` colors instead of giving a hex. Every value in
`zenwritten-dark.toml` is Zenbones' own.

Every palette must have the same roles; evaluation fails if one doesn't.
Adding a theme means adding a palette with those roles, which also adds it
to `systemProfile.theme`, and mapping it in each app above that uses a port.

- Wayle takes ten of the roles as `styling.palette` (`primary` is
  `accent`). Its config spells one `fg-muted` and its theme files
  `fg_muted`; Wayle's config schema doesn't catch the wrong one, it just
  falls back to Wayle's default color.
- Hyprland reads all of them from `hypr/hyprland/data/colors.lua`,
  generated by `home/apps/hyprland.nix`, as hex without the `#`. The
  window borders and hy3's tab bars use it.
- hyprshell and lazygit take them straight from `systemProfile.palette`.

## Settings saved by the apps

Some apps save a theme picked in their own settings, which could otherwise
win over the one set here.

| App | Where it saves | What happens |
|---|---|---|
| Vicinae | `~/.config/vicinae/settings.json` | The theme set here is loaded through `VICINAE_OVERRIDES` and wins over it on the next start. A theme picked in Vicinae lasts until then. |
| Wayle | `~/.config/wayle/runtime.toml` | It wins over the config, per setting. A config change clears its overrides of the colors, the theme provider and the fonts; until then a theme picked in Wayle's settings stays. `wayle config reset styling.palette.<role>` clears one sooner; a whole table can't be reset. |
| VS Code | nowhere | settings.json is read-only. |
| Neovim, Alacritty, Hyprland, hyprshell, lazygit | nowhere | |
