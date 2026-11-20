# Bottleneck Calculator Extreme

A Factorio 2.1 mod that tells you what to build next.

Pick the buildings you care about: your labs, a vatbrain, the assembler making productivity
modules. Set how fast each group should run. The mod scans the whole surface and works out, item
by item, how much their supply chain needs and how much your factory can make. You see what runs
short first, and by how much.

It is built for big bases, and Pyanodon's mods in particular, where following one chain by hand
takes an evening.

## How to use it

1. Press **ALT + B** or click the shortcut button to open the window.
2. Pick up the selection tool from the window. **Drag** over buildings to add them as targets;
   **right-drag** removes them. Ghosts count too.
3. Set a speed for each target group (0 to 200%) and press **Apply**.
4. Read the **Items** list. **Short** items come first, lowest coverage first: that's the order
   things run out in as your targets speed up. **Enough** lists what's covered.
5. **Click** any item for its report: every building that uses it (and how many are waiting for
   it right now), every building that makes it (and which of its own inputs are short), and what
   the item mostly turns into on the way to your targets. Click a building icon there to find
   those buildings on the map.
6. **Right-click** an item to treat it as unlimited (and again to count it).
7. Pin the window for a compact view that stays open while you build. Press **Refresh** after
   you build to see the new picture.

## How it works

The mod builds a linear program from every crafting building on the surface (recipes, modules,
beacons, productivity) and solves it with a revised simplex over a few ticks, with a
progress bar and a stop button. Speed changes continue from the last answer, so they take
under a second even on a large base.

- It uses the buildings you already have first, and only plans past them where it has to,
  pricing each extra building by how hard it is to fit in.
- Each item is counted as if everything it needs were there, so a shortage upstream never hides
  what's needed further down.
- Planned changes count as done: ghosts, pending upgrades and module requests are included.
- Power, fuel, heat and water are treated as unlimited. Steam is too, unless you turn on
  *Track steam* in the mod settings. Fuel waste such as ash and spent fuel cells is unlimited.

## Settings (per player)

- **Solver work per tick**: lower it to keep the game smoother while it works, at the cost of a
  longer wait.
- **Analyze belts and pipes**: traces belts, inserters and pipes to find furnace recipes and fluid
  temperatures. More accurate, slower to scan.
- **Track steam**: count steam as an item that can run short.
- **Maximum rows per section**: longer lists are cut off to keep the window responsive.

## Requirements

- Factorio 2.1
- [Production Rates Library](https://mods.factorio.com/mod/sw-rates-lib) (sw-rates-lib)
- [Logical Entity Tracker](https://mods.factorio.com/mod/sw-entity-tracker) (sw-entity-tracker)
- [Factorio Library](https://mods.factorio.com/mod/flib) (flib)

Space Age is not required.

## Credits

Inspired by SWeini's
[Production Rates Calculator Extreme](https://mods.factorio.com/mod/sw-rates-calc-extreme), and
built on their production rates library and entity tracker.

## Bugs and ideas

Open an issue on [GitHub](https://github.com/quasar-kyle-2/factorio-bottlenecks/issues) or post
on the mod portal's Discussion tab. A save file helps a lot.

## License

MIT, see [LICENSE](LICENSE).
