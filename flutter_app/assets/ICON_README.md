# App Icon — Phase Arc

## Files needed

| File | Size | Description |
|------|------|-------------|
| `icon.svg` | vector | Source design (checked in) |
| `icon.png` | 1024×1024 | Full icon — opaque, with `#0B1D13` background. Used by iOS and as the Android fallback. |
| `icon_foreground.png` | 1024×1024 | Android adaptive foreground only — the arc + dots on a **transparent** background. Android composites this over the `#0B1D13` adaptive background configured in `pubspec.yaml`. |

## How to generate the PNGs

From `icon.svg`, render at 1024×1024:

```bash
# Full icon (opaque background) — for icon.png
rsvg-convert -w 1024 -h 1024 icon.svg -o icon.png

# Foreground only (transparent) — for icon_foreground.png
# Edit the SVG: remove the <rect> background, then render.
```

Or open `icon.svg` in Figma / Inkscape / Affinity Designer and export.

## How to stamp the icons into the platform projects

```bash
cd flutter_app
flutter create .                    # regenerates android/ and ios/ if missing
dart run flutter_launcher_icons     # stamps PNGs into all mipmap-* and AppIcon.appiconset dirs
```

The `flutter_launcher_icons` config in `pubspec.yaml` handles all required
resolutions (48–192 dp Android, 60–180 pt iOS, 1024 App Store).

## Color spec

| Role | Hex |
|------|-----|
| Background | `#0B1D13` |
| Arc gradient start | `#22C55E` |
| Arc gradient end / impact accent | `#06B6D4` |
| Phase dots | `#FFFFFF` @ 85% opacity |
