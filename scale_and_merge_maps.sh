#!/usr/bin/env bash
# Scale PNGs using inch dimensions from filenames.
# - If a single map fits on A3 Portrait (297 × 420 mm), output it as its own A3 PDF.
# - Otherwise pack maps onto A0 Portrait pages (841 × 1189 mm), one PDF per page.
#
# Layout rules (A0 packing):
#   - Maps are placed top-to-bottom with GAP_IN between them
#   - Maps are centred horizontally; if a map exceeds A0 width it is scaled down
#   - When the next map would overflow the current page, a new A0 page is started
#
# Output:
#   a3_<mapname>.pdf          — maps that fit on A3 (one PDF each)
#   a0_page_001.pdf, ...      — remaining maps packed onto A0 pages

set -euo pipefail

### SETTINGS ###
dpi=96          # raster resolution
gap_in=1        # vertical gap between maps on A0 pages, in inches

# ── Page dimensions ──────────────────────────────────────────────────────────

# A3 Portrait (297 × 420 mm)
a3_w_mm=297
a3_h_mm=420
a3_w_px=$(awk -v mm="$a3_w_mm" -v d="$dpi" 'BEGIN{printf "%d", mm/25.4*d+0.5}')
a3_h_px=$(awk -v mm="$a3_h_mm" -v d="$dpi" 'BEGIN{printf "%d", mm/25.4*d+0.5}')

# A0 Portrait (841 × 1189 mm)
a0_w_mm=841
a0_h_mm=1189
a0_w_px=$(awk -v mm="$a0_w_mm" -v d="$dpi" 'BEGIN{printf "%d", mm/25.4*d+0.5}')
a0_h_px=$(awk -v mm="$a0_h_mm" -v d="$dpi" 'BEGIN{printf "%d", mm/25.4*d+0.5}')

gap_px=$((gap_in * dpi))

# Max map size in inches that fits each format
a3_max_w_in=$(awk -v mm="$a3_w_mm" 'BEGIN{printf "%.1f", mm/25.4}')
a3_max_h_in=$(awk -v mm="$a3_h_mm" 'BEGIN{printf "%.1f", mm/25.4}')
a0_max_w_in=$(awk -v mm="$a0_w_mm" 'BEGIN{printf "%.1f", mm/25.4}')
a0_max_h_in=$(awk -v mm="$a0_h_mm" 'BEGIN{printf "%.1f", mm/25.4}')

echo "A3 Portrait canvas: ${a3_w_px} × ${a3_h_px} px  (${a3_w_mm} × ${a3_h_mm} mm @ ${dpi} DPI)"
echo "   Max map size   : ${a3_max_w_in}\" × ${a3_max_h_in}\"  (= ${a3_w_mm} × ${a3_h_mm} mm)"
echo "A0 Portrait canvas: ${a0_w_px} × ${a0_h_px} px  (${a0_w_mm} × ${a0_h_mm} mm @ ${dpi} DPI)"
echo "   Max map size   : ${a0_max_w_in}\" × ${a0_max_h_in}\"  (= ${a0_w_mm} × ${a0_h_mm} mm)"
echo "Gap between maps  : ${gap_in}\" = ${gap_px} px"
echo ""

tmpdir="scaled_tmp"
rm -rf "$tmpdir"
mkdir -p "$tmpdir"

# ── 1. Collect & scale source PNGs ──────────────────────────────────────────

sources=()
while IFS= read -r -d '' file; do
  sources+=("$file")
done < <(find . -maxdepth 1 -type f -iname '*[0-9]x[0-9]*.png' -print0 | sort -z -V)

if [[ ${#sources[@]} -eq 0 ]]; then
  echo "No source PNGs with WxH pattern found. Aborting."
  exit 1
fi

# Arrays for maps going into A0 packing
scaled_list=()
scaled_w=()
scaled_h=()

# Track A3 outputs for summary
a3_outputs=()
a0_page_num=0

for f in "${sources[@]}"; do
  f="${f#./}"
  base="${f%.png}"

  dims=$(echo "$base" | grep -Eo '[0-9]+x[0-9]+' | tail -n1 || true)
  if [[ -z "$dims" ]]; then
    echo "⚠️  Skipping '$f' (no WxH inches pattern found)"
    continue
  fi

  w_in=${dims%x*}
  h_in=${dims#*x}
  if ! [[ "$w_in" =~ ^[0-9]+$ && "$h_in" =~ ^[0-9]+$ ]]; then
    echo "⚠️  Skipping '$f' (non-integer inches in '$dims')"
    continue
  fi

  w_px=$((w_in * dpi))
  h_px=$((h_in * dpi))

  echo "-> $f  (${w_in}x${h_in} in -> ${w_px}x${h_px} px)"

  # -- Decision: does this map fit on A3? (with optional 90 deg rotation) --
  rotate_a3=0
  fits_a3=0
  if [[ $w_px -le $a3_w_px && $h_px -le $a3_h_px ]]; then
    fits_a3=1
  elif [[ $h_px -le $a3_w_px && $w_px -le $a3_h_px ]]; then
    fits_a3=1
    rotate_a3=1
  fi

  if [[ $fits_a3 -eq 1 ]]; then
    if [[ $rotate_a3 -eq 1 ]]; then
      echo "   [rotated 90] Fits on A3 after rotation -- generating individual A3 PDF"
      tmp=$w_px; w_px=$h_px; h_px=$tmp
    else
      echo "   Fits on A3 -- generating individual A3 PDF"
    fi

    scaled_png="$tmpdir/scaled_a3_${base##*/}.png"
    if [[ $rotate_a3 -eq 1 ]]; then
      convert "$f" -rotate 90 -resize "${w_px}x${h_px}!" "$scaled_png"
    else
      convert "$f" -resize "${w_px}x${h_px}!" "$scaled_png"
    fi

    # Centre the map on a white A3 canvas
    canvas="$tmpdir/canvas_a3_${base##*/}.png"
    convert -size "${a3_w_px}x${a3_h_px}" xc:white "$canvas"

    x_offset=$(( (a3_w_px - w_px) / 2 ))
    y_offset=$(( (a3_h_px - h_px) / 2 ))

    convert "$canvas" "$scaled_png" \
      -geometry "+${x_offset}+${y_offset}" \
      -composite "$canvas"

    out_pdf="a3_${base##*/}.pdf"
    convert "$canvas" -units PixelsPerInch -density "$dpi" "$out_pdf"
    if [[ $rotate_a3 -eq 1 ]]; then
      echo "   OK ${out_pdf}  (A3 Portrait, ${a3_w_mm}x${a3_h_mm} mm, rotated 90 deg)"
    else
      echo "   OK ${out_pdf}  (A3 Portrait, ${a3_w_mm}x${a3_h_mm} mm)"
    fi
    a3_outputs+=("$out_pdf")

  else
    # -- Does not fit on A3 -> queue for A0 packing ----------------------
    # Try rotating to better fit A0 width
    rotate_a0=0
    if [[ $w_px -gt $a0_w_px && $h_px -le $a0_w_px ]]; then
      rotate_a0=1
      echo "   [rotated 90] Rotating to better fit A0 width"
      tmp=$w_px; w_px=$h_px; h_px=$tmp
    fi

    echo "   Does not fit on A3 -- queued for A0 packing"

    # Downscale if still wider than A0 canvas (preserve aspect ratio)
    if [[ $w_px -gt $a0_w_px ]]; then
      echo "   '$f' wider than A0 -- downscaling to fit width"
      h_px=$(awk -v h="$h_px" -v w="$w_px" -v aw="$a0_w_px" \
             'BEGIN{printf "%d", h * aw / w + 0.5}')
      w_px=$a0_w_px
    fi

    out="$tmpdir/scaled_$(printf '%03d' ${#scaled_list[@]})_${base##*/}.png"
    if [[ $rotate_a0 -eq 1 ]]; then
      convert "$f" -rotate 90 -resize "${w_px}x${h_px}!" "$out"
    else
      convert "$f" -resize "${w_px}x${h_px}!" "$out"
    fi

    scaled_list+=("$out")
    scaled_w+=("$w_px")
    scaled_h+=("$h_px")
  fi
done

# ── 2. Pack remaining maps onto A0 pages ─────────────────────────────────────

page_imgs=()
page_w=()
page_h=()
page_used=0

flush_page() {
  a0_page_num=$((a0_page_num + 1))
  local out_pdf
  out_pdf=$(printf "a0_page_%03d.pdf" "$a0_page_num")
  local canvas="$tmpdir/page_${a0_page_num}_canvas.png"

  echo ""
  echo "── A0 Page ${a0_page_num}: compositing ${#page_imgs[@]} map(s) → ${out_pdf}"

  convert -size "${a0_w_px}x${a0_h_px}" xc:white "$canvas"

  local y_offset=0
  for idx in "${!page_imgs[@]}"; do
    local img="${page_imgs[$idx]}"
    local iw="${page_w[$idx]}"
    local ih="${page_h[$idx]}"

    local x_offset=$(( (a0_w_px - iw) / 2 ))

    convert "$canvas" "$img" \
      -geometry "+${x_offset}+${y_offset}" \
      -composite "$canvas"

    echo "   placed $(basename "$img")  @ x=${x_offset} y=${y_offset}  (${iw}×${ih} px)"
    y_offset=$((y_offset + ih + gap_px))
  done

  convert "$canvas" -units PixelsPerInch -density "$dpi" "$out_pdf"
  echo "   ✅ ${out_pdf}  (A0 Portrait, ${a0_w_mm}×${a0_h_mm} mm)"
}

if [[ ${#scaled_list[@]} -gt 0 ]]; then
  echo ""
  echo "── Packing ${#scaled_list[@]} map(s) onto A0 page(s)..."

  for idx in "${!scaled_list[@]}"; do
    img="${scaled_list[$idx]}"
    iw="${scaled_w[$idx]}"
    ih="${scaled_h[$idx]}"

    local_gap=$(( ${#page_imgs[@]} > 0 ? gap_px : 0 ))
    needed=$(( local_gap + ih ))

    if [[ ${#page_imgs[@]} -gt 0 && $(( page_used + needed )) -gt $a0_h_px ]]; then
      flush_page
      page_imgs=()
      page_w=()
      page_h=()
      page_used=0
      local_gap=0
      needed=$ih
    fi

    page_imgs+=("$img")
    page_w+=("$iw")
    page_h+=("$ih")
    page_used=$(( page_used + local_gap + ih ))
  done

  if [[ ${#page_imgs[@]} -gt 0 ]]; then
    flush_page
  fi
fi

# ── 3. Summary ───────────────────────────────────────────────────────────────

echo ""
echo "========================================"
echo "✅ Done!"

if [[ ${#a3_outputs[@]} -gt 0 ]]; then
  echo ""
  echo "  A3 PDFs (${#a3_outputs[@]}):"
  for f in "${a3_outputs[@]}"; do
    echo "   → $f"
  done
  echo "  Canvas : A3 Portrait  ${a3_w_mm} × ${a3_h_mm} mm  @ ${dpi} DPI"
fi

if [[ $a0_page_num -gt 0 ]]; then
  echo ""
  echo "  A0 PDFs (${a0_page_num}):"
  for p in $(seq -f "%03g" 1 "$a0_page_num"); do
    f="a0_page_${p}.pdf"
    [[ -f "$f" ]] && echo "   → $f"
  done
  echo "  Canvas : A0 Portrait  ${a0_w_mm} × ${a0_h_mm} mm  @ ${dpi} DPI"
  echo "  Gap    : ${gap_in}\" = ${gap_px} px between maps"
fi

echo "========================================"
