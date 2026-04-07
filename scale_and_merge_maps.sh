#!/usr/bin/env bash
# Scale images using inch dimensions from filenames.
# - If a single map fits on A3 Portrait (297 x 420 mm), output it as its own A3 PDF.
# - Otherwise pack maps onto A0 Portrait pages (841 x 1189 mm), one PDF per page.
#
# Layout rules (A0 packing):
#   - Maps are placed top-to-bottom with GAP_IN between them
#   - Maps are centred horizontally; if a map exceeds A0 width it is scaled down
#   - When the next map would overflow the current page, a new A0 page is started
#
# Output:
#   a3_<mapname>.pdf          -- maps that fit on A3 (one PDF each)
#   a0_page_001.pdf, ...      -- remaining maps packed onto A0 pages

set -euo pipefail

# ── Arguments ────────────────────────────────────────────────────────────────

directory="."
output_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--directory)  directory="$2";   shift 2 ;;
    -o|--output-dir) output_dir="$2";  shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [-d|--directory DIR] [-o|--output-dir DIR]" >&2
      exit 1
      ;;
  esac
done

[[ -z "$output_dir" ]] && output_dir="$directory"
mkdir -p "$output_dir"

# ── Settings ──────────────────────────────────────────────────────────────────

dpi=96      # raster resolution
gap_in=1    # vertical gap between maps on A0 pages, in inches

# A3 Portrait (297 x 420 mm)
a3_w_mm=297; a3_h_mm=420
a3_w_px=$(awk -v mm="$a3_w_mm" -v d="$dpi" 'BEGIN{printf "%d", mm/25.4*d+0.5}')
a3_h_px=$(awk -v mm="$a3_h_mm" -v d="$dpi" 'BEGIN{printf "%d", mm/25.4*d+0.5}')

# A0 Portrait (841 x 1189 mm)
a0_w_mm=841; a0_h_mm=1189
a0_w_px=$(awk -v mm="$a0_w_mm" -v d="$dpi" 'BEGIN{printf "%d", mm/25.4*d+0.5}')
a0_h_px=$(awk -v mm="$a0_h_mm" -v d="$dpi" 'BEGIN{printf "%d", mm/25.4*d+0.5}')

gap_px=$((gap_in * dpi))

# Max map size in inches for each format
a3_max_w_in=$(awk -v mm="$a3_w_mm" 'BEGIN{printf "%.1f", mm/25.4}')
a3_max_h_in=$(awk -v mm="$a3_h_mm" 'BEGIN{printf "%.1f", mm/25.4}')
a0_max_w_in=$(awk -v mm="$a0_w_mm" 'BEGIN{printf "%.1f", mm/25.4}')
a0_max_h_in=$(awk -v mm="$a0_h_mm" 'BEGIN{printf "%.1f", mm/25.4}')

echo "A3 Portrait canvas: ${a3_w_px} x ${a3_h_px} px  (${a3_w_mm} x ${a3_h_mm} mm @ ${dpi} DPI)"
echo "   Max map size   : ${a3_max_w_in}\" x ${a3_max_h_in}\"  (= ${a3_w_mm} x ${a3_h_mm} mm)"
echo "A0 Portrait canvas: ${a0_w_px} x ${a0_h_px} px  (${a0_w_mm} x ${a0_h_mm} mm @ ${dpi} DPI)"
echo "   Max map size   : ${a0_max_w_in}\" x ${a0_max_h_in}\"  (= ${a0_w_mm} x ${a0_h_mm} mm)"
echo "Gap between maps  : ${gap_in}\" = ${gap_px} px"
echo "Source directory  : $(realpath "$directory")"
echo "Output directory  : $(realpath "$output_dir")"
echo ""

tmpdir="${output_dir}/scaled_tmp"
rm -rf "$tmpdir"
mkdir -p "$tmpdir"

# ── 1. Collect source images ──────────────────────────────────────────────────

sources=()
while IFS= read -r -d '' file; do
  sources+=("$file")
done < <(find "$directory" -maxdepth 1 -type f \
         \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.tiff" -o -iname "*.webp" \) \
         -iname "*[0-9]x[0-9]*" -print0 | sort -z -V)

if [[ ${#sources[@]} -eq 0 ]]; then
  echo "No source images with WxH pattern found in '${directory}'. Aborting."
  exit 1
fi

# Arrays for maps going into A0 packing
scaled_list=()
scaled_w=()
scaled_h=()

# A3 outputs for summary
a3_outputs=()
a0_page_num=0

# ── 2. Process each image ─────────────────────────────────────────────────────

for f in "${sources[@]}"; do
  # Filename without extension, basename only
  fname=$(basename "$f")
  base="${fname%.*}"

  dims=$(echo "$base" | grep -Eo '[0-9]+x[0-9]+' | tail -n1 || true)
  if [[ -z "$dims" ]]; then
    echo "WARNING: Skipping '$fname' (no WxH inches pattern found)"
    continue
  fi

  w_in=${dims%x*}
  h_in=${dims#*x}
  if ! [[ "$w_in" =~ ^[0-9]+$ && "$h_in" =~ ^[0-9]+$ ]]; then
    echo "WARNING: Skipping '$fname' (non-integer inches in '$dims')"
    continue
  fi

  w_px=$((w_in * dpi))
  h_px=$((h_in * dpi))

  echo "-> $fname  (${w_in}x${h_in} in = ${w_px}x${h_px} px)"

  # ── A3 check (portrait and rotated) ────────────────────────────────────────
  rotate=0
  fits_a3=0

  if [[ $w_px -le $a3_w_px && $h_px -le $a3_h_px ]]; then
    fits_a3=1
  elif [[ $h_px -le $a3_w_px && $w_px -le $a3_h_px ]]; then
    fits_a3=1
    rotate=1
  fi

  if [[ $fits_a3 -eq 1 ]]; then
    if [[ $rotate -eq 1 ]]; then
      echo "   [rotate 90] fits A3 after rotation"
      tmp=$w_px; w_px=$h_px; h_px=$tmp
    else
      echo "   fits A3"
    fi

    scaled_png="$tmpdir/a3_${base}.png"
    if [[ $rotate -eq 1 ]]; then
      convert "$f" -rotate 90 -resize "${w_px}x${h_px}!" "$scaled_png"
    else
      convert "$f" -resize "${w_px}x${h_px}!" "$scaled_png"
    fi

    # Centre on white A3 canvas
    canvas="$tmpdir/a3_canvas_${base}.png"
    convert -size "${a3_w_px}x${a3_h_px}" xc:white "$canvas"
    x_off=$(( (a3_w_px - w_px) / 2 ))
    y_off=$(( (a3_h_px - h_px) / 2 ))
    convert "$canvas" "$scaled_png" -geometry "+${x_off}+${y_off}" -composite "$canvas"

    out_pdf="${output_dir}/a3_${base}.pdf"
    convert "$canvas" -units PixelsPerInch -density "$dpi" "$out_pdf"

    rot_note=$([[ $rotate -eq 1 ]] && echo " [rotated 90 deg]" || echo "")
    echo "   -> ${out_pdf}  (A3 ${a3_w_mm}x${a3_h_mm} mm${rot_note})"
    a3_outputs+=("$out_pdf")

  else
    # ── Queue for A0 packing ───────────────────────────────────────────────
    rotate=0

    # Rotate if that would make it narrower than A0 width (and it currently exceeds it)
    if [[ $w_px -gt $a0_w_px && $h_px -le $a0_w_px ]]; then
      rotate=1
      echo "   [rotate 90] rotating to better fit A0 width"
      tmp=$w_px; w_px=$h_px; h_px=$tmp
    fi

    echo "   queued for A0 packing"

    # Downscale if still wider than A0 (preserve aspect ratio)
    if [[ $w_px -gt $a0_w_px ]]; then
      h_px=$(awk -v h="$h_px" -v w="$w_px" -v aw="$a0_w_px" \
             'BEGIN{printf "%d", h * aw / w + 0.5}')
      w_px=$a0_w_px
      echo "   downscaled to fit A0 width: ${w_px}x${h_px} px"
    fi

    out="$tmpdir/a0_$(printf '%03d' ${#scaled_list[@]})_${base}.png"
    if [[ $rotate -eq 1 ]]; then
      convert "$f" -rotate 90 -resize "${w_px}x${h_px}!" "$out"
    else
      convert "$f" -resize "${w_px}x${h_px}!" "$out"
    fi

    scaled_list+=("$out")
    scaled_w+=("$w_px")
    scaled_h+=("$h_px")
  fi
done

# ── 3. Pack A0 maps ───────────────────────────────────────────────────────────

# Declared before flush_page to ensure they are in scope as globals
page_imgs=()
page_w=()
page_h=()
page_used=0

flush_page() {
  a0_page_num=$((a0_page_num + 1))
  local out_pdf
  out_pdf=$(printf "%s/a0_page_%03d.pdf" "$output_dir" "$a0_page_num")
  local canvas="$tmpdir/a0_page_${a0_page_num}_canvas.png"

  echo ""
  echo "-- A0 page ${a0_page_num}: ${#page_imgs[@]} map(s) -> ${out_pdf}"

  convert -size "${a0_w_px}x${a0_h_px}" xc:white "$canvas"

  local y_off=0
  local idx
  for idx in "${!page_imgs[@]}"; do
    local img="${page_imgs[$idx]}"
    local iw="${page_w[$idx]}"
    local ih="${page_h[$idx]}"
    local x_off=$(( (a0_w_px - iw) / 2 ))

    convert "$canvas" "$img" -geometry "+${x_off}+${y_off}" -composite "$canvas"
    echo "   placed $(basename "$img")  @ +${x_off}+${y_off}  (${iw}x${ih} px)"
    y_off=$((y_off + ih + gap_px))
  done

  convert "$canvas" -units PixelsPerInch -density "$dpi" "$out_pdf"
  echo "   -> ${out_pdf}  (A0 ${a0_w_mm}x${a0_h_mm} mm)"
}

if [[ ${#scaled_list[@]} -gt 0 ]]; then
  echo ""
  echo "-- Packing ${#scaled_list[@]} map(s) onto A0 page(s)..."

  for idx in "${!scaled_list[@]}"; do
    img="${scaled_list[$idx]}"
    iw="${scaled_w[$idx]}"
    ih="${scaled_h[$idx]}"

    local_gap=$(( ${#page_imgs[@]} > 0 ? gap_px : 0 ))
    needed=$(( local_gap + ih ))

    # If the map doesn't fit upright but would fit rotated 90°, rotate it now.
    # Only useful if iw < ih (rotation reduces height).
    # Rotated: new height = iw, new width = ih — check ih fits A0 width and iw fits remaining.
    if [[ $(( page_used + needed )) -gt $a0_h_px \
       && $iw -lt $ih \
       && $ih -le $a0_w_px \
       && $(( local_gap + iw )) -le $(( a0_h_px - page_used )) ]]; then
      rotated_tmp="$tmpdir/rot_${idx}_$(basename "$img")"
      echo "   [rotate 90] rotating $(basename "$img") to fit remaining $(( a0_h_px - page_used - local_gap ))px on current page"
      convert "$img" -rotate 90 "$rotated_tmp"
      img="$rotated_tmp"
      # Swap dimensions
      tmp=$iw; iw=$ih; ih=$tmp
      needed=$(( local_gap + ih ))
    fi

    # If still doesn't fit (even after rotation), flush and start new page
    if [[ ${#page_imgs[@]} -gt 0 && $(( page_used + needed )) -gt $a0_h_px ]]; then
      flush_page
      page_imgs=(); page_w=(); page_h=()
      page_used=0; local_gap=0; needed=$ih
    fi

    page_imgs+=("$img")
    page_w+=("$iw")
    page_h+=("$ih")
    page_used=$(( page_used + local_gap + ih ))
  done

  [[ ${#page_imgs[@]} -gt 0 ]] && flush_page
fi

# ── 4. Summary ────────────────────────────────────────────────────────────────

echo ""
echo "========================================"
echo "Done!"

if [[ ${#a3_outputs[@]} -gt 0 ]]; then
  echo ""
  echo "  A3 PDFs (${#a3_outputs[@]}):"
  for f in "${a3_outputs[@]}"; do echo "   -> $f"; done
  echo "  Format : A3 Portrait  ${a3_w_mm} x ${a3_h_mm} mm  @ ${dpi} DPI"
fi

if [[ $a0_page_num -gt 0 ]]; then
  echo ""
  echo "  A0 PDFs (${a0_page_num}):"
  for p in $(seq -f "%03g" 1 "$a0_page_num"); do
    f="${output_dir}/a0_page_${p}.pdf"
    [[ -f "$f" ]] && echo "   -> $f"
  done
  echo "  Format : A0 Portrait  ${a0_w_mm} x ${a0_h_mm} mm  @ ${dpi} DPI"
  echo "  Gap    : ${gap_in}\" = ${gap_px} px between maps"
fi

echo "========================================"
