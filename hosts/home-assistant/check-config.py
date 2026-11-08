"""Check the generated YAML with the same no-pip mode as nixpkgs' hass wrapper."""
import asyncio
import importlib
import sys

from homeassistant.scripts import check_config as upstream


async def check():
    hass = upstream.core.HomeAssistant(sys.argv[1])
    # nixpkgs' packaged hass adds --skip-pip: dependencies come from Nix.
    # Still import every selected protocol's config flow below and fail on
    # schema errors/warnings; never mask missing imports or fetch from pip.
    hass.config.skip_pip = True
    upstream.loader.async_setup(hass)
    hass.config_entries = upstream.ConfigEntries(hass, {})
    await hass.config_entries.async_initialize()
    upstream.dr.async_setup(hass)
    await upstream.ar.async_load(hass)
    await upstream.dr.async_load(hass)
    await upstream.er.async_load(hass)
    await upstream.ir.async_load(hass, read_only=True)
    result = await upstream.async_check_ha_config_file(hass)
    await hass.async_stop(force=True)
    if result.errors or result.warnings:
        print("Configuration errors:", result.errors)
        print("Configuration warnings:", result.warnings)
        raise SystemExit(1)
    for domain in ("zha", "matter", "thread", "esphome", "bluetooth", "homekit", "wyoming", "llama_cpp"):
        importlib.import_module(f"homeassistant.components.{domain}.config_flow")
    print("Home Assistant YAML schema check and selected integration imports: passed")


asyncio.run(check(), loop_factory=upstream.runner.create_event_loop)
