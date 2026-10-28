# UniPass Inkan app icon

A vermilion round seal (印鑑) on warm paper, with a white phone outline whose screen carries a keyhole: the key stays locked inside the phone. The same artwork is used for both apps.

| File | What it is |
| --- | --- |
| `inkan-icon-clean.svg` | Source, plain colors: paper `#FCF0DF`, seal `#E3281B`, carving in the paper color. Full bleed 1024×1024, geometry only. |
| `inkan-icon-textured.svg` | Source, the same artwork with an ink-stamp texture (rough edges, specks, paper fibres) made with SVG filters. |
| `textured-1024.png` | The textured SVG rasterized by headless Chrome (AppKit doesn't render SVG filters). The filters use fixed seeds, so it's reproducible. |
| `ios-1024.png` | iOS icon for the signer: the plain artwork, 1024×1024, opaque sRGB, no alpha. iOS applies its own mask. Plain rather than textured because iOS shows the icon at 180 px and smaller, where the texture only lightens the red. |
| `macos-clean-1024.png`, `macos-textured-1024.png` | macOS masters: the artwork clipped to an 824×824 continuous-corner squircle (about 185 px corner radius), centered in a transparent 1024 canvas with a soft drop shadow (Big Sur icon grid). |
| `render.swift` | Renders one full-bleed source (SVG or PNG) into a full-bleed PNG and a macOS PNG. |
| `render.sh` | Runs the whole pipeline and rebuilds the coordinator's asset catalog. |

The macOS `AppIcon.appiconset` mixes the two: 128 px and smaller come from the plain version (texture turns into noise when small), 256 px and larger from the textured one.

The apps keep the system accent color: a vermilion tint would make primary buttons such as Send and Execute look like destructive actions.

## Regenerate

After editing either SVG, run this from the repository root. It uses `swift` and `sips`, and Google Chrome for the textured version (without Chrome it keeps the existing `textured-1024.png`):

```sh
sh design/app-icon/render.sh
```
