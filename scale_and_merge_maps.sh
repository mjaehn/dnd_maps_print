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
# Fit-check (A0):
#   After collecting all A0 maps the script reports how much downscaling would
#   be needed to fit them all onto a single A0 page.
#   --max-downscale PCT  If the required downscale is within PCT %, apply it
#                        automatically so all maps land on one page.
#   Example: --max-downscale 10  (allow up to 10 % size reduction)
#
# Output:
#   a3_<mapname>.pdf          -- maps that fit on A3 (one PDF each)
#   a0_page_001.pdf, ...      -- remaining maps packed onto A0 pages

set -euo pipefail

# ── Arguments ────────────────────────────────────────────────────────────────

directory="."
output_dir=""
max_downscale=0   # max allowable downscale % to fit all A0 maps on one page (0 = report only)

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--directory)   directory="$2";     shift 2 ;;
    -o|--output-dir)  output_dir="$2";    shift 2 ;;
    --max-downscale)  max_downscale="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [-d|--directory DIR] [-o|--output-dir DIR] [--max-downscale PCT]" >&2
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
echo "Max downscale     : ${max_downscale}%  (0 = report only, no auto-scaling)"
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
    png_to_pdf "$canvas" "$out_pdf"

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

# ── 2.5 Fit-check: downscale table for consecutive groups ────────────────────
#
# For every consecutive group of 2 or more A0 maps reports how much downscaling
# would be needed to place that group on a single A0 page.
# The gap between maps is kept fixed (not scaled).
# If --max-downscale PCT is given, groups within budget are flagged; the actual
# per-page downscaling is applied automatically during packing (section 3).

if [[ ${#scaled_list[@]} -gt 1 ]]; then
  echo ""
  echo "Fit check — downscale needed to place consecutive maps on one A0 page:"
  echo "  (gap of ${gap_in}\" between maps is kept constant)"
  echo ""

  fc_n=${#scaled_list[@]}
  fc_any_hint=0

  for fc_s in $(seq 0 $(( fc_n - 1 ))); do
    for fc_e in $(seq $(( fc_s + 1 )) $(( fc_n - 1 ))); do
      fc_group_h=0
      for fc_i in $(seq $fc_s $fc_e); do
        fc_group_h=$(( fc_group_h + scaled_h[fc_i] ))
      done
      fc_cnt=$(( fc_e - fc_s + 1 ))
      fc_gaps=$(( (fc_cnt - 1) * gap_px ))
      fc_avail=$(( a0_h_px - fc_gaps ))

      # Build short name list from filenames (strip a0_NNN_ prefix and .png)
      fc_names=""
      for fc_i in $(seq $fc_s $fc_e); do
        fc_bn=$(basename "${scaled_list[$fc_i]}")
        fc_nm="${fc_bn#a0_[0-9][0-9][0-9]_}"; fc_nm="${fc_nm%.png}"
        fc_names="${fc_names:+${fc_names}, }${fc_nm}"
      done

      if [[ $(( fc_group_h + fc_gaps )) -le $a0_h_px ]]; then
        printf "  maps %d-%d  (%s): already fit — no downscale needed\n" \
          $(( fc_s + 1 )) $(( fc_e + 1 )) "$fc_names"
      elif [[ $fc_avail -le 0 ]]; then
        printf "  maps %d-%d  (%s): fixed gaps alone exceed A0 height\n" \
          $(( fc_s + 1 )) $(( fc_e + 1 )) "$fc_names"
      else
        fc_pct=$(awk -v h="$fc_group_h" -v av="$fc_avail" \
          'BEGIN{printf "%.1f", (1 - av/h) * 100}')
        fc_hint=""
        if awk -v p="$fc_pct" -v md="$max_downscale" \
             'BEGIN{exit (md+0 > 0 && p+0 <= md+0) ? 0 : 1}' 2>/dev/null; then
          fc_hint="  [within --max-downscale ${max_downscale}% budget → will be merged]"
          fc_any_hint=1
        fi
        printf "  maps %d-%d  (%s): need %s%% downscale%s\n" \
          $(( fc_s + 1 )) $(( fc_e + 1 )) "$fc_names" "$fc_pct" "$fc_hint"
      fi
    done
  done

  echo ""
  if [[ $fc_any_hint -eq 1 ]]; then
    echo "  Groups marked above will be downscaled and merged onto one A0 page during packing."
  elif awk -v md="$max_downscale" 'BEGIN{exit (md+0 > 0) ? 0 : 1}' 2>/dev/null; then
    echo "  No consecutive group fits within --max-downscale ${max_downscale}%; all maps packed at original size."
  else
    echo "  Use --max-downscale <PCT> to automatically merge and downscale groups onto one A0 page."
  fi
fi

# ── 3. Pack A0 maps ───────────────────────────────────────────────────────────

# Declared before flush_page to ensure they are in scope as globals
page_imgs=()
page_w=()
page_h=()
page_used=0

# Converts a canvas PNG to a PDF, embedding the configured DPI.
# Uses img2pdf (avoids ImageMagick's PDF security-policy restriction).
png_to_pdf() {
  local src="$1" dst="$2"
  local tmp="${src%.png}_pdftmp.png"
  convert "$src" -units PixelsPerInch -density "$dpi" "$tmp"
  python3 -m img2pdf "$tmp" -o "$dst"
  rm -f "$tmp"
}

# Rescales all images on the current page by the minimum factor needed to fit
# within A0 height, if max_downscale > 0 and the needed % is within budget.
# Updates page_imgs, page_w, page_h, page_used in-place.
apply_page_downscale() {
  [[ $max_downscale -eq 0 ]] && return 0
  [[ ${#page_imgs[@]} -eq 0 ]] && return 0

  local _maps_h=0
  local _ph
  for _ph in "${page_h[@]}"; do _maps_h=$(( _maps_h + _ph )); done
  local _n=${#page_imgs[@]}
  local _gaps=$(( (_n > 1 ? _n - 1 : 0) * gap_px ))
  local _total=$(( _maps_h + _gaps ))
  [[ $_total -le $a0_h_px ]] && return 0

  local _avail=$(( a0_h_px - _gaps ))
  [[ $_avail -le 0 ]] && return 0

  local _pct
  _pct=$(awk -v h="$_maps_h" -v av="$_avail" 'BEGIN{printf "%.1f", (1-av/h)*100}')
  awk -v p="$_pct" -v md="$max_downscale" 'BEGIN{exit (p+0 <= md+0) ? 0 : 1}' || return 0

  local _sf
  _sf=$(awk -v p="$_pct" 'BEGIN{printf "%.6f", 1-p/100}')
  echo "   [page downscale ${_pct}%] rescaling ${_n} map(s) to fit on one A0 page"

  local _new_used=0
  local _i
  for _i in "${!page_imgs[@]}"; do
    local _nw _nh
    _nw=$(awk -v v="${page_w[$_i]}" -v s="$_sf" 'BEGIN{printf "%d", v*s+0.5}')
    _nh=$(awk -v v="${page_h[$_i]}" -v s="$_sf" 'BEGIN{printf "%d", v*s+0.5}')
    local _nimg="${page_imgs[$_i]%.png}_pgds.png"
    convert "${page_imgs[$_i]}" -resize "${_nw}x${_nh}!" "$_nimg"
    page_imgs[$_i]="$_nimg"
    page_w[$_i]=$_nw
    page_h[$_i]=$_nh
    local _lg=$(( _i > 0 ? gap_px : 0 ))
    _new_used=$(( _new_used + _lg + _nh ))
  done
  page_used=$_new_used
}

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

  png_to_pdf "$canvas" "$out_pdf"
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
       && $(( a0_h_px - page_used - local_gap )) -gt 0 \
       && $(( local_gap + iw )) -le $(( a0_h_px - page_used )) ]]; then
      rotated_tmp="$tmpdir/rot_${idx}_$(basename "$img")"
      echo "   [rotate 90] rotating $(basename "$img") to fit remaining $(( a0_h_px - page_used - local_gap ))px on current page"
      convert "$img" -rotate 90 "$rotated_tmp"
      img="$rotated_tmp"
      # Swap dimensions
      tmp=$iw; iw=$ih; ih=$tmp
      needed=$(( local_gap + ih ))
    fi

    # Check whether adding this map to the current page stays within the downscale budget.
    # If so, accumulate rather than flushing (apply_page_downscale will handle it at flush time).
    _within_ds_budget=0
    if [[ $max_downscale -gt 0 && ${#page_imgs[@]} -gt 0 \
       && $(( page_used + needed )) -gt $a0_h_px ]]; then
      _tent_maps_h=0
      for _th in "${page_h[@]}"; do _tent_maps_h=$(( _tent_maps_h + _th )); done
      _tent_maps_h=$(( _tent_maps_h + ih ))
      _tent_gaps=$(( ${#page_imgs[@]} * gap_px ))   # n existing maps → n gaps after adding 1
      _tent_avail=$(( a0_h_px - _tent_gaps ))
      if [[ $_tent_avail -gt 0 ]]; then
        _within_ds_budget=$(awk -v h="$_tent_maps_h" -v av="$_tent_avail" -v md="$max_downscale" \
          'BEGIN{pct=(1-av/h)*100; print (pct <= md+0) ? 1 : 0}')
      fi
    fi

    # If still doesn't fit (even after rotation) and not within downscale budget, flush and start new page
    if [[ ${#page_imgs[@]} -gt 0 && $(( page_used + needed )) -gt $a0_h_px \
       && $_within_ds_budget -eq 0 ]]; then
      apply_page_downscale
      flush_page
      page_imgs=(); page_w=(); page_h=()
      page_used=0; local_gap=0; needed=$ih
    fi

    page_imgs+=("$img")
    page_w+=("$iw")
    page_h+=("$ih")
    page_used=$(( page_used + local_gap + ih ))
  done

  if [[ ${#page_imgs[@]} -gt 0 ]]; then
    apply_page_downscale
    flush_page
  fi
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
