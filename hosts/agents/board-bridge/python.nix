# The Python board-bridge runs with, and its check tests with. discord.py
# without voice, which would bring ffmpeg and opus for nothing.
{ pkgs }:
pkgs.python3.withPackages (ps: [ (ps.discordpy.override { withVoice = false; }) ])
