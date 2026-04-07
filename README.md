# dnd_maps_print
Scale D&D maps to A0 or A3 format for printing.

## Requirements

- [ImageMagick](https://imagemagick.org/) (`convert` must be on `PATH`)

## Usage

```bash
./scale_and_merge_maps.sh [OPTIONS]
```

### Options

| Option | Default | Description |
|---|---|---|
| `-d`, `--directory DIR` | `.` | Directory containing the source images |
| `-t`, `--file-type TYPE` | `jpeg` | Image file extension to look for (e.g. `png`, `jpg`, `webp`) |
| `-o`, `--output-dir DIR` | same as `--directory` | Directory where output PDFs are written |

### Examples

```bash
# Process JPEGs in the current directory, output PDFs alongside them
./scale_and_merge_maps.sh

# Process PNGs in a specific folder
./scale_and_merge_maps.sh -d ~/maps -t png

# Write PDFs to a separate output folder
./scale_and_merge_maps.sh -d ~/maps -t png -o ~/maps/pdf
```

## File naming convention

Source images must include a `WxH` pattern in their filename (width × height in inches), e.g.:

```
dungeon_30x22.jpeg
worldmap_44x33.png
```

## Output

- Maps that fit on **A3 Portrait** (297 × 420 mm) are written as individual `a3_<name>.pdf` files.
- Larger maps are packed onto **A0 Portrait** (841 × 1189 mm) pages and written as `a0_page_001.pdf`, `a0_page_002.pdf`, etc.

All output PDFs are placed in the output directory (defaults to the source directory).
