# Nameplate Targets

A World of Warcraft addon that shows who each nameplate's unit is targeting, right under (or over) the nameplate, in that player's class color:

```
> [faction icon] Firstname <
```

Built for **WoW: Forever**, and it also works on retail **Midnight** (both run on the same 12.x addon API). It works with the default nameplates, **EllesmereUI** and **ElvUI**.

## Features

- Target's name in their class color, with a custom format (default `> NAME <`)
- Horde / Alliance icon before player names (toggle and size)
- First name only (default) or full name with surname
- Custom text and color when the unit is targeting you (default `>> YOU <<`)
- Font (including LibSharedMedia fonts), size, outline and shadow
- Above or below the nameplate, with X/Y offsets
- Toggles for NPC targets, enemy plates and friendly plates
- Test mode for setting things up out of combat

## Install

1. Download `PlateTarget-<version>.zip` from [Releases](../../releases).
2. Extract the `PlateTarget` folder into:
   - WoW Forever: `World of Warcraft/_forever_/Interface/AddOns/`
   - Retail: `World of Warcraft/_retail_/Interface/AddOns/`

## Commands

| Command | What it does |
| --- | --- |
| `/ptarget` | Open the options panel |
| `/ptarget test` | Toggle test mode (sample text on every nameplate) |
| `/ptarget reset` | Reset all settings |
| `/ptarget debug` | Print API / anchoring info for your target's nameplate |

## Restricted content

Midnight-era clients hide some unit info from addons ("secret values"), mostly inside instances. PlateTarget only passes that info to display functions, so it won't error. When info is hidden it degrades: the faction icon is left out, the class color falls back to white, or the bare name shows without the brackets. If something looks wrong, run `/ptarget debug` and include the output in an issue.
