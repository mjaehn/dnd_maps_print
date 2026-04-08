# dnd_maps_print
Scale D&D maps to A0 or A3 format for printing.

## Requirements

- [ImageMagick](https://imagemagick.org/) (`convert` must be on `PATH`)
- [img2pdf](https://gitlab.mister-muffin.de/josch/img2pdf) (`pip install img2pdf`) — used for PDF generation to work around ImageMagick's default PDF security policy

## Usage

```bash
./scale_and_merge_maps.sh [OPTIONS]
```

### Options

| Option | Default | Description |
|---|---|---|
| `-d`, `--directory DIR` | `.` | Directory containing the source images |
| `-o`, `--output-dir DIR` | same as `--directory` | Directory where output PDFs are written |
| `--max-downscale PCT` | `0` (report only) | Maximum downscale percentage to apply when merging A0 maps onto fewer pages |

### Examples

```bash
# Process images in the current directory, output PDFs alongside them
./scale_and_merge_maps.sh

# Process images in a specific folder
./scale_and_merge_maps.sh -d ~/maps

# Write PDFs to a separate output folder
./scale_and_merge_maps.sh -d ~/maps -o ~/maps/pdf

# Allow up to 10% downscale to merge maps that almost fit on one A0 page
./scale_and_merge_maps.sh -d ~/maps --max-downscale 10
```

## File naming convention

Source images must include a `WxH` pattern in their filename (width × height in inches). Any image format supported by ImageMagick is accepted, e.g.:

```
dungeon_30x22.jpeg
worldmap_44x33.png
```

## Output

- Maps that fit on **A3 Portrait** (297 × 420 mm) are written as individual `a3_<name>.pdf` files.
- Larger maps are packed onto **A0 Portrait** (841 × 1189 mm) pages and written as `a0_page_001.pdf`, `a0_page_002.pdf`, etc.

All output PDFs are placed in the output directory (defaults to the source directory).

## Layout rules (A0 packing)

- Maps are placed **top-to-bottom** with a 1-inch gap between them.
- Maps are **centred horizontally**; if a map exceeds A0 width it is automatically scaled down to fit.
- A map is **rotated 90°** if that allows it to fit better (narrower than A0 width, or to stay on the current page).
- When the next map would overflow the current page, a **new A0 page** is started.

## Fit-check and automatic downscaling

After collecting all A0 maps, the script prints a table showing how much downscaling would be needed to place every **consecutive group** of 2 or more maps onto a single A0 page:

```
Fit check — downscale needed to place consecutive maps on one A0 page:
  (gap of 1" between maps is kept constant)

  maps 1-2  (dungeon_30x22, forest_28x20): need 8.3% downscale
  maps 2-3  (forest_28x20, cave_32x26):    need 14.1% downscale
  maps 1-3  (dungeon_30x22, forest_28x20, cave_32x26): need 21.5% downscale

  Use --max-downscale <PCT> to automatically merge and downscale groups onto one A0 page.
```

When `--max-downscale PCT` is given, any consecutive group that fits within the budget is automatically scaled down and merged onto a single A0 page. Groups that exceed the budget are packed normally (potentially across multiple pages).

The gap between maps is always kept at its fixed size — only the map images themselves are scaled.
