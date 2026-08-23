# App Icon — Phase Arc

## Files needed

| File | Size | Description |
|------|------|-------------|
| `icon.svg` | vector | Source design (checked in) |
| `icon.png` | 1024×1024 | Full icon — opaque, with `#0B1D13` background. Used by iOS and as the Android fallback. |
| `icon_foreground.png` | 1024×1024 | Android adaptive foreground only — the arc + dots on a **transparent** background, scaled into the safe zone (see below). Android composites this over the `#0B1D13` adaptive background configured in `pubspec.yaml`. |

## How to generate the PNGs

From `icon.svg`, render at 1024×1024:

```bash
# Full icon (opaque background) — for icon.png
rsvg-convert -w 1024 -h 1024 icon.svg -o icon.png

# Foreground only (transparent) — for icon_foreground.png
# Edit the SVG: remove the <rect> background, then render.
```

Or open `icon.svg` in Figma / Inkscape / Affinity Designer and export.

Save with the `.png` extension. `flutter_launcher_icons` resolves the paths in
`pubspec.yaml` literally — an extension-less export is silently not found.

## Safe-zone scaling for `icon_foreground.png`

**Do not render the foreground full-bleed.** Android masks an adaptive icon to
an OEM-chosen shape; only the centre **66 of 108 dp** (0.611 of the canvas) is
guaranteed visible. The Phase Arc design puts its extremities — the address,
top, and impact dots — right at the edge of the artwork's bounding box, so a
full-bleed foreground loses the top dot under a circular mask.

`flutter_launcher_icons` already wraps the foreground in `<inset 16%>` in the
generated `mipmap-anydpi-v26/ic_launcher.xml`, which shrinks it to 0.68 of the
icon — not enough on its own for this design. Size the art so the two compose
correctly:

```
target radius in icon_foreground.png = (66/108) / (1 - 2×0.16) = 0.899
```

That is: scale the artwork so the smallest circle enclosing every opaque pixel
has a diameter of **0.899 × 1024 ≈ 920 px**, centred on the canvas. After the
16% inset it lands exactly on the 66 dp safe circle. Centre on the enclosing
circle, not the bounding box — the arc is not vertically centred in its bbox.

Re-check this if `flutter_launcher_icons` ever changes its inset.

## iOS alpha channel

`pubspec.yaml` sets `remove_alpha_ios: true`. `icon.png` is fully opaque but
still carries an alpha channel, and App Store Connect rejects icon assets that
have one. Without this flag the tool warns and the build is rejected at upload.

## How to stamp the icons into the platform projects

```bash
cd flutter_app
flutter create .                    # regenerates android/ and ios/ if missing
dart run flutter_launcher_icons     # stamps PNGs into all mipmap-*/drawable-* and AppIcon.appiconset dirs
```

The `flutter_launcher_icons` config in `pubspec.yaml` handles all required
resolutions (48–192 dp Android launcher, 108–432 px adaptive foreground,
60–180 pt iOS, 1024 App Store).

## Color spec

| Role | Hex |
|------|-----|
| Background | `#0B1D13` |
| Arc gradient start | `#22C55E` |
| Arc gradient end / impact accent | `#06B6D4` |
| Phase dots | `#FFFFFF` @ 85% opacity |
