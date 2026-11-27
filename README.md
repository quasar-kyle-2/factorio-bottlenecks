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
6. Check **Project recommendations**: recipes you don't use yet that would save the most
   effort, each built fresh. A short item with a red **!** is better handled by one of them
   than by more of the buildings you have.
7. **Right-click** an item to treat it as unlimited (and again to count it).
8. Pin the window for a compact view that stays open while you build. Press **Refresh** after
   you build to see the new picture. After a few changes it carries on from the last answer, so
   it's back in seconds.

## How it works

The mod builds a linear program from every crafting building on the surface (recipes, modules,
beacons, productivity) and solves it with a revised simplex over a few ticks, with a
progress bar and a stop button. Speed changes continue from the last answer, so they take
under a second even on a large base.

Refresh does the same when the factory changed only a little since the last answer: buildings
added or removed, other modules or recipes, ghosts. It matches the new scan's building groups to
the last plan, changes what changed, and lets the solver carry on from there (a dual simplex
brings the plan back within the new limits). The answer is the same as working it out from
scratch. It starts from scratch anyway after research or a change to the recipes you have
unlocked (Pyanodon's TURD choices included), mod settings or mods, unlimited items or targets,
when the factory needs an item it didn't before (or stops needing one), when a few hundred
building groups changed at once, or when carrying on takes more than a quarter of the work of
the last full analysis.

- It uses the buildings you already have first, and only plans past them where it has to,
  pricing each extra building by how hard it is to fit in (its build cost): its width, a belt,
  pipe or fuel for each thing it uses or makes (plus half for each extra lane when one lane of
  your best belt can't carry it), and 0.05 per MW of power it draws, for the power plant behind
  it. One more building of a group you have is cheaper than a new one, since its belts are
  already there.
- Between plans of about the same build cost, it picks the one with the lowest running cost
  (items and fluids handled, and energy), so a power-hungry route doesn't win just because its
  buildings are idle.
- Each item is counted as if everything it needs were there, so a shortage upstream never hides
  what's needed further down.
- Planned changes count as done: ghosts, pending upgrades and module requests are included.
- Power, fuel, heat and water at its default temperature are treated as unlimited, and so is
  what burning fuel leaves behind (ash, spent fuel cells). Steam, hot water and waste a recipe
  makes are counted like any other item. Fuels made for one kind of building (drill heads, fuel
  rods) are counted too.
- Items that come from outside (deliveries, hand-feeding, nexelit ore from dig sites) are capped
  at what came in during the last hour.
- After the results show, it looks for projects: every recipe you have unlocked but don't use,
  in every building type you have. The 40 most promising at the plan's prices are each tried on
  a copy of the solved plan, and the 10 that save the most build cost are listed, with how much
  running cost they save.

## Settings (per player)

- **Solver work per tick**: lower it to keep the game smoother while it works, at the cost of a
  longer wait.
- **Analyze belts and pipes**: traces belts, inserters and pipes to find furnace recipes and fluid
  temperatures. More accurate, slower to scan.
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
