## Entangled Goyim v1.0.3

### Changes
- The mod now installs into its own folder, `mods/goyim.ew`, so it can sit next to the original Entangled Worlds mod (`mods/quant.ew`) instead of overwriting it.
- The proxy keeps its settings and saved runs in its own folder too. The first time it starts, it copies your settings (nickname, colors, Noita location) from the old folder.
- When the proxy enables Slugma's Entangled Goyim, it turns off Quant's Entangled Worlds. If both end up enabled, Slugma's Entangled Goyim stays inactive and tells you to disable one.
- The mod download is now `goyim.ew.zip`.
- **Crash recovery:** the mod keeps its own backup of your wands, items, spells, perks, gold and HP. If a crash leaves you with a fresh starting character when you continue, a prompt offers to restore them. The backup is cleared when you die, so it can't bring back items after a death.

### Updating from an earlier version
If you're on v1.0.0, download the new proxy below by hand once; its updater can't find the renamed downloads. From v1.0.1 onward, the proxy's update button works.

The proxy installs the mod into the new folder automatically. Your old `mods/quant.ew` folder is left alone, because the original mod may still be using it. If you don't play the original mod, you can delete that folder.

### Installation

Download `goyim_proxy-win.zip`, `goyim_proxy-linux.zip`, `goyim_proxy-macos-arm64.zip` (Apple Silicon) or `goyim_proxy-macos-intel.zip` (Intel) below, unpack it and launch the proxy. The proxy can download and install the mod automatically.
