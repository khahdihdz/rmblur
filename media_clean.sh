#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  media_clean.sh  ·  Xoá watermark tĩnh + làm nét ảnh/video trên Termux
#  Version : 1.0.0
#  Repo    : https://github.com/khahdihdz/rmblur
#
#  Cài nhanh:
#     pkg install -y ffmpeg imagemagick python
#     termux-setup-storage            # nếu cần đọc /sdcard
#     chmod +x media_clean.sh && ./media_clean.sh
#
#  Chỉ dùng cho nội dung bạn sở hữu hoặc có quyền chỉnh sửa.
# =============================================================================
set -o pipefail
shopt -s nullglob

APP_NAME="media_clean"
VERSION="1.0.0"

# ----------------------------- màu -------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
  C_B=$'\033[36m'; C_D=$'\033[2m';  C_0=$'\033[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_D=''; C_0=''
fi

# ----------------------------- đường dẫn -------------------------------------
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
STATE_DIR="${MEDIA_CLEAN_HOME:-$HOME/.media_clean}"
PRESET_DIR="$STATE_DIR/presets"
LOG_DIR="$STATE_DIR/logs"
SETTINGS_FILE="$STATE_DIR/settings.conf"

mkdir -p "$PRESET_DIR" "$LOG_DIR" 2>/dev/null || true

LOGFILE="$LOG_DIR/run_$(date '+%Y%m%d_%H%M%S')_$$.log"
: >"$LOGFILE" 2>/dev/null || LOGFILE="/dev/null"

# ----------------------------- mặc định --------------------------------------
CRF=23
X264_PRESET="medium"
UNSHARP_IMG="0x1.2+1.0+0.02"
UNSHARP_VID="5:5:1.0:5:5:0.0"
INPAINT_RADIUS=7
OUT_DIR="$PWD/output"

# ----------------------------- trạng thái ------------------------------------
REGIONS=()
DO_DEBLUR=0
FRAME_W=0
FRAME_H=0
IM_BIN=()
IDENTIFY_BIN=()
CV2_OK=0
TMP_DIR=""

# ----------------------------- tiện ích --------------------------------------
_log() {
  local lvl="$1"; shift
  printf '%s [%-4s] %s\n' "$(date '+%F %T')" "$lvl" "$*" >>"$LOGFILE" 2>/dev/null || true
}
info() { _log INFO "$*"; printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { _log OK   "$*"; printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { _log WARN "$*"; printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { _log ERR  "$*"; printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }

pause() { printf '\n%sNhấn Enter để tiếp tục...%s' "$C_D" "$C_0"; IFS= read -r _ || true; }

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'echo; cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

ensure_tmp() {
  if [[ -z "$TMP_DIR" || ! -d "$TMP_DIR" ]]; then
    TMP_DIR=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/$APP_NAME.XXXXXX") \
      || die "Không tạo được thư mục tạm"
  fi
}

expand_path() {
  local p="$1"
  p="${p%\"}"; p="${p#\"}"
  p="${p%\'}"; p="${p#\'}"
  p="${p/#\~/$HOME}"
  printf '%s\n' "$p"
}

ask() {
  local prompt="$1" def="${2-}"
  if [[ -n "$def" ]]; then
    printf '%s [%s]: ' "$prompt" "$def" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  IFS= read -r REPLY || return 1
  if [[ -z "$REPLY" && -n "$def" ]]; then
    REPLY="$def"
  fi
  return 0
}

confirm() {
  local prompt="$1" def="${2:-n}" ans
  if [[ "$def" == "y" ]]; then
    printf '%s (Y/n): ' "$prompt" >&2
  else
    printf '%s (y/N): ' "$prompt" >&2
  fi
  IFS= read -r ans || return 1
  ans="${ans:-$def}"
  case "$ans" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

is_number() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# x:y:w:h -> "x y w h"
parse_region() {
  local r="${1:-}"
  if [[ ! "$r" =~ ^([0-9]+):([0-9]+):([0-9]+):([0-9]+)$ ]]; then
    return 1
  fi
  local x="${BASH_REMATCH[1]}" y="${BASH_REMATCH[2]}"
  local w="${BASH_REMATCH[3]}" h="${BASH_REMATCH[4]}"
  (( w > 0 && h > 0 )) || return 1
  printf '%s %s %s %s\n' "$x" "$y" "$w" "$h"
}

clamp_region() {
  local r="$1" W="$2" H="$3" x y w h
  read -r x y w h < <(parse_region "$r") || return 1
  (( W > 2 && H > 2 )) || return 1
  (( x < 1 )) && x=1
  (( y < 1 )) && y=1
  (( x > W - 2 )) && x=$(( W - 2 ))
  (( y > H - 2 )) && y=$(( H - 2 ))
  (( x + w > W - 1 )) && w=$(( W - 1 - x ))
  (( y + h > H - 1 )) && h=$(( H - 1 - y ))
  (( w > 0 && h > 0 )) || return 1
  printf '%s:%s:%s:%s\n' "$x" "$y" "$w" "$h"
}

unique_out() {
  local base="$1" ext="$2" out n=1
  out="$base.$ext"
  while [[ -e "$out" ]]; do
    out="${base}_$n.$ext"
    n=$((n + 1))
  done
  printf '%s\n' "$out"
}

detect_im() {
  if command -v magick >/dev/null 2>&1; then
    IM_BIN=(magick)
    IDENTIFY_BIN=(magick identify)
  elif command -v convert >/dev/null 2>&1; then
    IM_BIN=(convert)
    IDENTIFY_BIN=(identify)
  else
    IM_BIN=()
    IDENTIFY_BIN=()
  fi
}

detect_cv2() {
  if command -v python >/dev/null 2>&1 && python -c 'import cv2' >/dev/null 2>&1; then
    CV2_OK=1
  else
    CV2_OK=0
  fi
}

# ----------------------------- ffprobe ---------------------------------------
probe_video_size() {
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height -of csv=p=0:s=x "$1" 2>/dev/null | head -n1
}

probe_duration_ms() {
  local d
  d=$(ffprobe -v error -show_entries format=duration \
        -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1)
  awk -v v="$d" 'BEGIN { if (v ~ /^[0-9.]+$/) printf "%d\n", v * 1000; else print 0 }'
}

probe_image_size() {
  [[ ${#IDENTIFY_BIN[@]} -gt 0 ]] || return 1
  "${IDENTIFY_BIN[@]}" -format '%w %h\n' "$1[0]" 2>/dev/null | head -n1
}

# ----------------------------- thanh tiến độ ---------------------------------
_bar() {
  local pct="$1" n=$(( $1 * 30 / 100 )) i s=""
  for ((i = 0; i < 30; i++)); do
    if (( i < n )); then s+="#"; else s+="."; fi
  done
  printf '%s' "$s"
}

_progress_reader() {
  local total_ms="${1:-0}" key val cur pct
  while IFS='=' read -r key val; do
    case "$key" in
      out_time_us)
        cur="${val//[!0-9]/}"
        [[ -z "$cur" ]] && continue
        if (( total_ms > 0 )); then
          pct=$(( cur / 1000 * 100 / total_ms ))
          (( pct < 0 )) && pct=0
          (( pct > 100 )) && pct=100
          printf '\r  %3d%% [%s]' "$pct" "$(_bar "$pct")"
        else
          printf '\r  %ss' "$(( cur / 1000000 ))"
        fi
        ;;
    esac
  done
  printf '\r  %3d%% [%s]\n' 100 "$(_bar 100)"
}

run_with_progress() {
  local total_ms="$1"; shift
  ensure_tmp
  local errlog="$TMP_DIR/ffmpeg.err"
  local -a st
  : >"$errlog"

  "$@" -progress pipe:1 -nostats -nostdin 2>"$errlog" | _progress_reader "$total_ms"
  st=("${PIPESTATUS[@]}")

  if (( st[0] != 0 )); then
    err "ffmpeg thất bại (mã ${st[0]}). 20 dòng cuối:"
    tail -n 20 "$errlog" >&2 || true
    return 1
  fi
  return 0
}

# ----------------------------- ảnh -------------------------------------------
write_inpaint_helper() {
  ensure_tmp
  local py="$TMP_DIR/inpaint.py"
  [[ -f "$py" ]] && return 0
  cat >"$py" <<'PY'
import sys
import cv2
import numpy as np

radius = int(sys.argv[1])
src = sys.argv[2]
dst = sys.argv[3]
regions = sys.argv[4:]

img = cv2.imread(src, cv2.IMREAD_UNCHANGED)
if img is None:
    sys.stderr.write("Khong doc duoc anh: %s\n" % src)
    sys.exit(1)

h, w = img.shape[:2]
mask = np.zeros((h, w), np.uint8)
for r in regions:
    try:
        x, y, rw, rh = (int(v) for v in r.split(":"))
    except ValueError:
        continue
    x = max(0, min(x, w))
    y = max(0, min(y, h))
    x2 = max(0, min(x + rw, w))
    y2 = max(0, min(y + rh, h))
    if x2 > x and y2 > y:
        mask[y:y2, x:x2] = 255

if int(mask.sum()) == 0:
    sys.stderr.write("Khong co vung hop le\n")
    sys.exit(1)

if img.ndim == 3 and img.shape[2] == 4:
    bgr = img[:, :, :3]
    alpha = img[:, :, 3]
    res = cv2.inpaint(bgr, mask, radius, cv2.INPAINT_TELEA)
    out = np.dstack([res, alpha])
elif img.ndim == 3 and img.shape[2] == 3:
    out = cv2.inpaint(img, mask, radius, cv2.INPAINT_TELEA)
elif img.ndim == 2:
    out = cv2.inpaint(img, mask, radius, cv2.INPAINT_TELEA)
else:
    sys.stderr.write("Dinh dang anh khong ho tro\n")
    sys.exit(1)

if not cv2.imwrite(dst, out):
    sys.stderr.write("Khong ghi duoc: %s\n" % dst)
    sys.exit(1)
PY
}

python_inpaint() {
  local in="$1" out="$2"
  write_inpaint_helper
  python "$TMP_DIR/inpaint.py" "$INPAINT_RADIUS" "$in" "$out" "${REGIONS[@]}"
}

im_region_blur() {
  local in="$1" out="$2"
  if [[ ${#IM_BIN[@]} -eq 0 ]]; then
    err "Cần ImageMagick để xử lý ảnh"
    return 1
  fi
  ensure_tmp
  local ext="png" cur="$in" n=0 r x y w h tmp
  [[ "$in" == *.* ]] && ext="${in##*.}"

  for r in "${REGIONS[@]}"; do
    read -r x y w h < <(parse_region "$r") || continue
    n=$((n + 1))
    tmp="$TMP_DIR/im_$$_$n.$ext"
    if ! "${IM_BIN[@]}" "$cur" \
        -region "${w}x${h}+${x}+${y}" -blur 0x15 +region "$tmp" \
        2>>"$LOGFILE"; then
      # ImageMagick 7 có thể bỏ -region: dùng crop + composite
      if ! "${IM_BIN[@]}" "$cur" \
          \( +clone -crop "${w}x${h}+${x}+${y}" +repage -blur 0x15 \) \
          -geometry "+${x}+${y}" -composite "$tmp" 2>>"$LOGFILE"; then
        err "ImageMagick lỗi ở vùng $r"
        return 1
      fi
    fi
    cur="$tmp"
  done

  if [[ "$cur" == "$in" ]]; then
    cp -- "$in" "$out" || return 1
  else
    mv -- "$cur" "$out" || return 1
  fi
}

process_image() {
  local in="$1" out="$2"
  local work="$in" step="" ext="png"

  [[ -f "$in" ]] || { err "Không thấy file: $in"; return 1; }
  ensure_tmp
  [[ "$in" == *.* ]] && ext="${in##*.}"
  step="$TMP_DIR/img_$$.$ext"

  if (( ${#REGIONS[@]} > 0 )); then
    if (( CV2_OK == 1 )); then
      if ! python_inpaint "$in" "$step"; then
        warn "OpenCV lỗi, chuyển sang ImageMagick"
        step="$TMP_DIR/img_im_$$.$ext"
        im_region_blur "$in" "$step" || return 1
      fi
    else
      im_region_blur "$in" "$step" || return 1
    fi
    work="$step"
  fi

  if [[ "$DO_DEBLUR" == "1" ]]; then
    if [[ ${#IM_BIN[@]} -eq 0 ]]; then
      warn "Không có ImageMagick, bỏ qua bước làm nét"
      cp -- "$work" "$out" || return 1
      return 0
    fi
    "${IM_BIN[@]}" "$work" -unsharp "$UNSHARP_IMG" "$out" 2>>"$LOGFILE" || {
      err "ImageMagick không ghi được $out"
      return 1
    }
  else
    if [[ "$work" == "$in" ]]; then
      cp -- "$in" "$out" || return 1
    else
      mv -- "$work" "$out" || return 1
    fi
  fi
  return 0
}

# ----------------------------- video -----------------------------------------
build_video_filter() {
  local -a parts=()
  local r c x y w h
  for r in "${REGIONS[@]}"; do
    if ! c=$(clamp_region "$r" "$FRAME_W" "$FRAME_H"); then
      warn "Bỏ qua vùng không hợp lệ: $r"
      continue
    fi
    IFS=: read -r x y w h <<<"$c"
    parts+=("delogo=x=$x:y=$y:w=$w:h=$h:show=0")
  done
  if [[ "$DO_DEBLUR" == "1" && -n "$UNSHARP_VID" ]]; then
    parts+=("unsharp=$UNSHARP_VID")
  fi
  if (( ${#parts[@]} == 0 )); then
    printf ''
    return 0
  fi
  local IFS=,
  printf '%s' "${parts[*]}"
}

process_video() {
  local in="$1" out="$2"
  local size dur vf
  local -a cmd

  [[ -f "$in" ]] || { err "Không thấy file: $in"; return 1; }
  if ! command -v ffmpeg >/dev/null 2>&1; then
    err "Chưa cài ffmpeg (pkg install ffmpeg)"
    return 1
  fi

  size=$(probe_video_size "$in")
  if [[ ! "$size" =~ ^[0-9]+x[0-9]+$ ]]; then
    err "Không đọc được kích thước video: $in"
    return 1
  fi
  FRAME_W="${size%x*}"
  FRAME_H="${size#*x}"

  vf=$(build_video_filter)
  if [[ -z "$vf" ]]; then
    warn "Không có filter nào để áp dụng"
    return 1
  fi

  dur=$(probe_duration_ms "$in")

  cmd=(ffmpeg -hide_banner -loglevel warning -y -i "$in"
       -vf "$vf" -map 0:v:0 -map '0:a?' -map_metadata 0
       -c:a copy -c:v libx264 -crf "$CRF" -preset "$X264_PRESET")

  case "$out" in
    *.mp4|*.mov|*.m4v) cmd+=(-movflags +faststart) ;;
  esac

  cmd+=("$out")

  info "Video: ${FRAME_W}x${FRAME_H} · filter: $vf"
  info "CRF=$CRF · preset=$X264_PRESET · audio copy"
  run_with_progress "$dur" "${cmd[@]}"
}

# ----------------------------- menu -----------------------------------------
ask_regions() {
  REGIONS=()
  printf '%sNhập vùng watermark dạng x:y:w:h (Enter trống để kết thúc)%s\n' "$C_D" "$C_0"
  local r
  while true; do
    ask "  Vùng $(( ${#REGIONS[@]} + 1 ))" ""
    r="$REPLY"
    [[ -z "$r" ]] && break
    if ! parse_region "$r" >/dev/null; then
      warn "Sai định dạng. Ví dụ đúng: 120:40:200:80"
      continue
    fi
    REGIONS+=("$r")
  done
  (( ${#REGIONS[@]} > 0 ))
}

menu_single_image() {
  local in size base ext out
  ask "Đường dẫn ảnh" ""
  in=$(expand_path "$REPLY")
  [[ -f "$in" ]] || { err "Không thấy file: $in"; return 1; }

  size=$(probe_image_size "$in" 2>/dev/null) || size=""
  if [[ -n "$size" ]]; then
    info "Kích thước ảnh: ${size% *}x${size#* } (rộng x cao)"
  else
    warn "Không đọc được kích thước ảnh (thiếu ImageMagick?)"
  fi

  if ask_regions; then
    info "Sẽ xoá ${#REGIONS[@]} vùng watermark"
  else
    warn "Không có vùng watermark, chỉ chạy làm nét"
  fi

  if confirm "Làm nét ảnh?" "y"; then DO_DEBLUR=1; else DO_DEBLUR=0; fi

  ask "Thư mục output" "$OUT_DIR"
  OUT_DIR=$(expand_path "$REPLY")
  mkdir -p "$OUT_DIR" || { err "Không tạo được $OUT_DIR"; return 1; }

  base="${in##*/}"; base="${base%.*}"
  ext="png"
  [[ "$in" == *.* ]] && ext="${in##*.}"
  out=$(unique_out "$OUT_DIR/${base}_clean" "$ext")

  if process_image "$in" "$out"; then
    ok "Đã lưu: $out"
  else
    err "Xử lý ảnh thất bại"
  fi
}

menu_single_video() {
  local in size base ext out t
  ask "Đường dẫn video" ""
  in=$(expand_path "$REPLY")
  [[ -f "$in" ]] || { err "Không thấy file: $in"; return 1; }

  size=$(probe_video_size "$in")
  if [[ "$size" =~ ^[0-9]+x[0-9]+$ ]]; then
    info "Kích thước video: ${size/x/ x } (rộng x cao)"
  else
    err "Không đọc được video: $in"
    return 1
  fi
  info "Thời lượng: $(( $(probe_duration_ms "$in") / 1000 )) giây"

  if ask_regions; then
    info "Sẽ xoá ${#REGIONS[@]} vùng watermark"
  else
    warn "Không có vùng watermark, chỉ chạy làm nét"
  fi

  if confirm "Làm nét video (unsharp)?" "n"; then DO_DEBLUR=1; else DO_DEBLUR=0; fi

  ask "Thư mục output" "$OUT_DIR"
  OUT_DIR=$(expand_path "$REPLY")
  mkdir -p "$OUT_DIR" || { err "Không tạo được $OUT_DIR"; return 1; }

  base="${in##*/}"; base="${base%.*}"
  ext="mp4"
  [[ "$in" == *.* ]] && ext="${in##*.}"
  out=$(unique_out "$OUT_DIR/${base}_clean" "$ext")

  if process_video "$in" "$out"; then
    ok "Đã lưu: $out"
  else
    err "Xử lý video thất bại"
  fi
}

menu_batch() {
  local kind="$1" dir outdir r f base ext out n=0 failed=0
  local -a files=() exts=() list=()
  local -A seen=()

  if [[ "$kind" == "image" ]]; then
    exts=(jpg jpeg png webp bmp tif tiff heic)
  else
    exts=(mp4 mkv mov webm avi m4v ts)
  fi

  ask "Thư mục nguồn" "$PWD"
  dir=$(expand_path "$REPLY")
  [[ -d "$dir" ]] || { err "Không phải thư mục: $dir"; return 1; }

  for ext in "${exts[@]}"; do
    files+=("$dir"/*."$ext")
    files+=("$dir"/*."${ext^^}")
  done

  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    [[ -n "${seen[$f]:-}" ]] && continue
    seen[$f]=1
    list+=("$f")
  done

  if (( ${#list[@]} == 0 )); then
    warn "Không tìm thấy file $kind nào trong $dir"
    return 1
  fi

  info "Tìm thấy ${#list[@]} file $kind"

  if ask_regions; then
    info "Áp dụng ${#REGIONS[@]} vùng cho tất cả file"
  else
    warn "Không có vùng watermark, chỉ chạy làm nét"
  fi

  if confirm "Làm nét?" "n"; then DO_DEBLUR=1; else DO_DEBLUR=0; fi

  ask "Thư mục output" "$dir/cleaned"
  outdir=$(expand_path "$REPLY")
  mkdir -p "$outdir" || { err "Không tạo được $outdir"; return 1; }

  local total=${#list[@]}
  for f in "${list[@]}"; do
    n=$((n + 1))
    base="${f##*/}"; base="${base%.*}"
    ext="png"
    [[ "$f" == *.* ]] && ext="${f##*/}"; ext="${ext##*.}"
    out=$(unique_out "$outdir/${base}_clean" "$ext")
    printf '\n%s[%d/%d]%s %s\n' "$C_B" "$n" "$total" "$C_0" "${f##*/}"
    if [[ "$kind" == "image" ]]; then
      process_image "$f" "$out" || { failed=$((failed + 1)); continue; }
    else
      process_video "$f" "$out" || { failed=$((failed + 1)); continue; }
    fi
  done

  printf '\n'
  ok "Hoàn tất: $((total - failed))/$total thành công · $failed lỗi"
  info "Output: $outdir"
  [[ -s "$LOGFILE" ]] && info "Log: $LOGFILE"
}

menu_preview() {
  local p size t out
  ask "Đường dẫn ảnh/video" ""
  p=$(expand_path "$REPLY")
  [[ -f "$p" ]] || { err "Không thấy file: $p"; return 1; }

  size=$(probe_video_size "$p" 2>/dev/null) || size=""
  if [[ -z "$size" ]]; then
    size=$(probe_image_size "$p" 2>/dev/null) || size=""
  fi

  if [[ -z "$size" ]]; then
    err "Không đọc được file này"
    return 1
  fi
  info "Kích thước: ${size% *}x${size#* }"

  ensure_tmp
  out="$PWD/preview_$(date +%s).png"
  if [[ "$size" == *" "* ]]; then
    cp -- "$p" "$out" 2>/dev/null || { err "Không copy được file"; return 1; }
  else
    ask "Lấy frame tại giây thứ" "0"
    t="$REPLY"
    is_number "${t%.*}" || t=0
    ffmpeg -hide_banner -loglevel error -ss "$t" -i "$p" -frames:v 1 -y "$out" \
      || { err "Không trích được frame"; return 1; }
  fi

  ok "Ảnh xem trước: $out"
  printf '%sMở ảnh bằng app xem ảnh, đọc toạ độ pixel của góc trên-trái và kích thước vùng,\n' "$C_D"
  printf 'rồi nhập lại dạng x:y:w:h. delogo cần chừa ít nhất 1px quanh vùng.%s\n' "$C_0"
}

# ----------------------------- preset & cài đặt -------------------------------
safe_name() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }

preset_save() {
  local name file
  ask "Tên preset" ""
  name="$REPLY"
  if ! safe_name "$name"; then
    err "Tên chỉ được chứa chữ, số, _ và -"
    return 1
  fi
  if ! ask_regions; then
    warn "Preset không có vùng watermark"
  fi
  file="$PRESET_DIR/$name.conf"
  {
    printf '# preset %s · %s\n' "$name" "$(date '+%F %T')"
    printf 'WATERMARKS="%s"\n' "${REGIONS[*]}"
    printf 'UNSHARP_IMG="%s"\n' "$UNSHARP_IMG"
    printf 'UNSHARP_VID="%s"\n' "$UNSHARP_VID"
    printf 'CRF="%s"\n' "$CRF"
    printf 'INPAINT_RADIUS="%s"\n' "$INPAINT_RADIUS"
  } >"$file" || { err "Không ghi được $file"; return 1; }
  ok "Đã lưu preset: $file"
}

preset_list() {
  local -a files=("$PRESET_DIR"/*.conf)
  if (( ${#files[@]} == 0 )); then
    warn "Chưa có preset nào trong $PRESET_DIR"
    return 1
  fi
  printf '%sPreset có sẵn:%s\n' "$C_B" "$C_0"
  local f
  for f in "${files[@]}"; do
    printf '  - %s\n' "${f##*/}"
  done
}

preset_load() {
  local name file line k v
  preset_list || return 1
  ask "Chọn preset (không cần .conf)" ""
  name="$REPLY"; name="${name%.conf}"
  file="$PRESET_DIR/$name.conf"
  [[ -f "$file" ]] || { err "Không thấy preset: $name"; return 1; }

  while IFS= read -r line; do
    line="${line%%#*}"
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    v="${v%\"}"; v="${v#\"}"
    case "$k" in
      WATERMARKS) read -r -a REGIONS <<<"$v" ;;
      UNSHARP_IMG) UNSHARP_IMG="$v" ;;
      UNSHARP_VID) UNSHARP_VID="$v" ;;
      CRF) CRF="$v" ;;
      INPAINT_RADIUS) INPAINT_RADIUS="$v" ;;
    esac
  done <"$file"

  ok "Đã nạp preset '$name' (${#REGIONS[@]} vùng, CRF=$CRF)"
}

preset_delete() {
  local name file
  preset_list || return 1
  ask "Xoá preset" ""
  name="$REPLY"; name="${name%.conf}"
  file="$PRESET_DIR/$name.conf"
  [[ -f "$file" ]] || { err "Không thấy preset: $name"; return 1; }
  confirm "Xoá $file ?" "n" || { info "Đã huỷ"; return 0; }
  rm -f -- "$file" && ok "Đã xoá preset '$name'"
}

menu_presets() {
  local c
  while true; do
    printf '\n%s--- Preset ---%s\n' "$C_B" "$C_0"
    printf '  1) Liệt kê\n  2) Lưu preset mới\n  3) Nạp preset\n  4) Xoá preset\n  0) Quay lại\n'
    printf 'Chọn: '
    IFS= read -r c || return 0
    case "$c" in
      1) preset_list ;;
      2) preset_save ;;
      3) preset_load ;;
      4) preset_delete ;;
      0) return 0 ;;
      *) warn "Lựa chọn không hợp lệ" ;;
    esac
    pause
  done
}

settings_load() {
  [[ -f "$SETTINGS_FILE" ]] || return 0
  local line k v
  while IFS= read -r line; do
    line="${line%%#*}"
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    v="${v%\"}"; v="${v#\"}"
    case "$k" in
      CRF) CRF="$v" ;;
      X264_PRESET) X264_PRESET="$v" ;;
      UNSHARP_IMG) UNSHARP_IMG="$v" ;;
      UNSHARP_VID) UNSHARP_VID="$v" ;;
      INPAINT_RADIUS) INPAINT_RADIUS="$v" ;;
      OUT_DIR) OUT_DIR="$v" ;;
    esac
  done <"$SETTINGS_FILE"
}

settings_save() {
  {
    printf 'CRF="%s"\n' "$CRF"
    printf 'X264_PRESET="%s"\n' "$X264_PRESET"
    printf 'UNSHARP_IMG="%s"\n' "$UNSHARP_IMG"
    printf 'UNSHARP_VID="%s"\n' "$UNSHARP_VID"
    printf 'INPAINT_RADIUS="%s"\n' "$INPAINT_RADIUS"
    printf 'OUT_DIR="%s"\n' "$OUT_DIR"
  } >"$SETTINGS_FILE" && ok "Đã lưu cài đặt: $SETTINGS_FILE"
}

menu_settings() {
  local c
  while true; do
    printf '\n%s--- Cài đặt mặc định ---%s\n' "$C_B" "$C_0"
    printf '  1) CRF (chất lượng video)      : %s\n' "$CRF"
    printf '  2) Preset x264                 : %s\n' "$X264_PRESET"
    printf '  3) Unsharp ảnh                 : %s\n' "$UNSHARP_IMG"
    printf '  4) Unsharp video               : %s\n' "$UNSHARP_VID"
    printf '  5) Bán kính inpaint            : %s\n' "$INPAINT_RADIUS"
    printf '  6) Thư mục output mặc định     : %s\n' "$OUT_DIR"
    printf '  7) Lưu ra settings.conf\n  0) Quay lại\n'
    printf 'Chọn: '
    IFS= read -r c || return 0
    case "$c" in
      1) ask "CRF (0-51, thấp = nét hơn)" "$CRF"; is_number "$REPLY" && CRF="$REPLY" || warn "Giá trị không hợp lệ" ;;
      2) ask "x264 preset" "$X264_PRESET"; X264_PRESET="$REPLY" ;;
      3) ask "Unsharp ảnh" "$UNSHARP_IMG"; UNSHARP_IMG="$REPLY" ;;
      4) ask "Unsharp video" "$UNSHARP_VID"; UNSHARP_VID="$REPLY" ;;
      5) ask "Bán kính inpaint" "$INPAINT_RADIUS"; is_number "$REPLY" && INPAINT_RADIUS="$REPLY" || warn "Giá trị không hợp lệ" ;;
      6) ask "Thư mục output" "$OUT_DIR"; OUT_DIR=$(expand_path "$REPLY") ;;
      7) settings_save ;;
      0) return 0 ;;
      *) warn "Lựa chọn không hợp lệ" ;;
    esac
    pause
  done
}

# ----------------------------- phụ thuộc -------------------------------------
check_deps() {
  local -a missing=()
  local c
  printf '%s--- Kiểm tra phụ thuộc ---%s\n' "$C_B" "$C_0"

  for c in ffmpeg ffprobe python; do
    if command -v "$c" >/dev/null 2>&1; then
      ok "$c: $(command -v "$c")"
    else
      err "$c: thiếu"
      missing+=("$c")
    fi
  done

  detect_im
  if [[ ${#IM_BIN[@]} -gt 0 ]]; then
    ok "ImageMagick: ${IM_BIN[*]}"
  else
    err "ImageMagick: thiếu"
    missing+=("imagemagick")
  fi

  detect_cv2
  if (( CV2_OK == 1 )); then
    ok "OpenCV (python cv2): có"
  else
    warn "OpenCV (python cv2): không có → dùng ImageMagick để xoá watermark ảnh"
  fi

  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "Đủ phụ thuộc"
    return 0
  fi

  local pkgs="${missing[*]}"
  warn "Thiếu: ${missing[*]}"
  printf 'Lệnh cài: %spkg install -y %s%s\n' "$C_D" "$pkgs" "$C_0" >&2
  if confirm "Chạy lệnh cài ngay?" "n"; then
    # shellcheck disable=SC2086
    pkg install -y $pkgs || err "Cài đặt thất bại, chạy lại thủ công"
    detect_im
    detect_cv2
    return 0
  fi
  return 1
}

show_log() {
  local -a files=("$LOG_DIR"/*.log)
  if (( ${#files[@]} == 0 )); then
    warn "Chưa có log nào"
    return 1
  fi
  local last="${files[${#files[@]} - 1]}"
  printf '%sLog gần nhất: %s%s\n' "$C_B" "$last" "$C_0"
  tail -n 40 "$last"
}

# ----------------------------- CLI -------------------------------------------
usage() {
  cat <<EOF
$APP_NAME $VERSION - xoá watermark tĩnh & làm nét ảnh/video (Termux)

CÁCH DÙNG
  $APP_NAME                     mở menu tương tác
  $APP_NAME --check             kiểm tra phụ thuộc
  $APP_NAME --version           in phiên bản
  $APP_NAME image FILE [x:y:w:h ...] [--deblur] [--out DIR]
  $APP_NAME video FILE [x:y:w:h ...] [--deblur] [--out DIR] [--crf N]

VÍ DỤ
  $APP_NAME video clip.mp4 900:20:180:60 20:60:120:40
  $APP_NAME image logo.png 100:100:200:80 --deblur
  $APP_NAME video in.mp4 940:12:180:60 --crf 20 --out ~/out

GHI CHÚ
  - delogo chỉ hiệu quả với watermark tĩnh, cùng vị trí trên mọi frame.
  - Làm nét chỉ tăng tương phản cạnh, không phục hồi chi tiết đã mất.
  - Chỉ dùng cho nội dung bạn sở hữu hoặc có quyền chỉnh sửa.
EOF
}

cli_mode() {
  local mode="$1"; shift
  local -a pos=() regs=()
  local outdir="" i f

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --deblur) DO_DEBLUR=1; shift ;;
      --out)
        (( $# >= 2 )) || { err "--out cần giá trị"; return 2; }
        outdir="$2"; shift 2
        ;;
      --crf)
        (( $# >= 2 )) || { err "--crf cần giá trị"; return 2; }
        CRF="$2"; shift 2
        ;;
      -h|--help) usage; return 0 ;;
      --) shift; while [[ $# -gt 0 ]]; do pos+=("$1"); shift; done ;;
      -*) err "Tham số không hỗ trợ: $1"; return 2 ;;
      *)
        if (( ${#pos[@]} == 0 )); then pos+=("$1"); else regs+=("$1"); fi
        shift
        ;;
    esac
  done

  (( ${#pos[@]} > 0 )) || { usage; return 2; }
  f=$(expand_path "${pos[0]}")
  [[ -f "$f" ]] || { err "Không thấy file: $f"; return 1; }

  for i in "${regs[@]}"; do
    if parse_region "$i" >/dev/null; then
      REGIONS+=("$i")
    else
      err "Vùng không hợp lệ: $i"
      return 2
    fi
  done

  OUT_DIR="${outdir:-$OUT_DIR}"
  OUT_DIR=$(expand_path "$OUT_DIR")
  mkdir -p "$OUT_DIR" || { err "Không tạo được $OUT_DIR"; return 1; }

  local base ext out
  base="${f##*/}"; base="${base%.*}"
  ext="png"
  [[ "$f" == *.* ]] && ext="${f##*.}"
  out=$(unique_out "$OUT_DIR/${base}_clean" "$ext")

  case "$mode" in
    image)
      command -v ffmpeg >/dev/null 2>&1 || warn "Không có ffmpeg (chỉ cần khi xử lý video)"
      detect_im
      detect_cv2
      process_image "$f" "$out" && ok "Đã lưu: $out"
      ;;
    video)
      process_video "$f" "$out" && ok "Đã lưu: $out"
      ;;
    *) err "Chế độ không hợp lệ: $mode"; return 2 ;;
  esac
}

# ----------------------------- menu chính ------------------------------------
main_menu() {
  local c
  detect_im
  detect_cv2

  while true; do
    clear 2>/dev/null || true
    printf '\n%s============================================%s\n' "$C_B" "$C_0"
    printf '%s  %s %s%s  ·  ảnh & video · Termux\n' "$C_B" "$APP_NAME" "$VERSION" "$C_0"
    printf '%s============================================%s\n' "$C_B" "$C_0"
    printf '  1) Xử lý 1 ảnh\n'
    printf '  2) Xử lý 1 video\n'
    printf '  3) Xử lý hàng loạt ảnh trong thư mục\n'
    printf '  4) Xử lý hàng loạt video trong thư mục\n'
    printf '  5) Xem trước / chọn toạ độ vùng watermark\n'
    printf '  6) Preset\n'
    printf '  7) Kiểm tra & cài phụ thuộc\n'
    printf '  8) Cài đặt mặc định\n'
    printf '  9) Xem log gần nhất\n'
    printf '  0) Thoát\n'
    printf '%s--------------------------------------------%s\n' "$C_D" "$C_0"
    printf 'Chọn: '
    if ! IFS= read -r c; then
      printf '\n'
      return 0
    fi
    case "$c" in
      1) menu_single_image; pause ;;
      2) menu_single_video; pause ;;
      3) menu_batch image; pause ;;
      4) menu_batch video; pause ;;
      5) menu_preview; pause ;;
      6) menu_presets ;;
      7) check_deps; pause ;;
      8) menu_settings ;;
      9) show_log; pause ;;
      0) return 0 ;;
      *) warn "Lựa chọn không hợp lệ"; sleep 0.5 ;;
    esac
  done
}

# ----------------------------- entrypoint ------------------------------------
main() {
  settings_load
  if (( $# == 0 )); then
    main_menu
    exit 0
  fi
  case "$1" in
    -h|--help|help) usage; exit 0 ;;
    -V|--version|version) printf '%s %s\n' "$APP_NAME" "$VERSION"; exit 0 ;;
    --check|check) check_deps; exit $? ;;
    image|video)
      cli_mode "$@"
      exit $?
      ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
