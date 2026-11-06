# The Python paperclip-events runs with, and its check tests with: aiohttp
# for the websocket, which board-bridge already brings through discord.py.
{ pkgs }:
pkgs.python3.withPackages (ps: [ ps.aiohttp ])
