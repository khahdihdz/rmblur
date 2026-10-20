#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  media_clean.sh  ·  Watermark + mosaic/pixel + làm nét + tự phát hiện vùng
#  Version : 1.3.0
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
VERSION="1.3.0"

# ----------------------------- màu -------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
  C_B=$'\033[36m'; C_D=$'\033[2m';  C_0=$'\033[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_D=''; C_0=''
fi

# ----------------------------- đường dẫn -------------------------------------
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
export SCRIPT_DIR
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
MOSAIC_BLOCK=8
MOSAIC_METHOD="smooth"
AUTO_DETECT=0
DETECT_MAX_IMAGE=1280
DETECT_MAX_VIDEO=960
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
    finish_image "$work" "$out" "$in"
    return $?
  fi
  if [[ "$work" == "$in" ]]; then
    cp -- "$in" "$out" || return 1
  else
    mv -- "$work" "$out" || return 1
  fi
  return 0
}

# ----------------------------- khử mosaic/pixel (ảnh) ------------------------
write_depixel_helper() {
  ensure_tmp
  local py="$TMP_DIR/depixel.py"
  [[ -f "$py" ]] && return 0
  cat >"$py" <<'PY'
import sys
import cv2

block = max(2, int(sys.argv[1]))
src = sys.argv[2]
dst = sys.argv[3]
regions = sys.argv[4:]

img = cv2.imread(src, cv2.IMREAD_UNCHANGED)
if img is None:
    sys.stderr.write("Khong doc duoc anh: %s\n" % src)
    sys.exit(1)

h, w = img.shape[:2]
changed = False
for r in regions:
    try:
        x, y, rw, rh = (int(v) for v in r.split(":"))
    except ValueError:
        continue
    x = max(0, min(x, w - 1))
    y = max(0, min(y, h - 1))
    rw = min(rw, w - x)
    rh = min(rh, h - y)
    if rw < 4 or rh < 4:
        continue
    # thu nhỏ về đúng lưới khối rồi phóng lại: làm mềm cạnh khối
    bw = max(1, rw // block)
    bh = max(1, rh // block)
    roi = img[y:y + rh, x:x + rw]
    small = cv2.resize(roi, (bw, bh), interpolation=cv2.INTER_AREA)
    big = cv2.resize(small, (rw, rh), interpolation=cv2.INTER_CUBIC)
    # làm mềm cạnh khối còn sót, sigma theo kích thước khối
    big = cv2.GaussianBlur(big, (0, 0), max(1.0, block / 6.0))
    img[y:y + rh, x:x + rw] = big
    changed = True

if not changed:
    sys.stderr.write("Khong co vung hop le\n")
    sys.exit(1)

if not cv2.imwrite(dst, img):
    sys.stderr.write("Khong ghi duoc: %s\n" % dst)
    sys.exit(1)
PY
}

python_depixel() {
  local in="$1" out="$2"
  write_depixel_helper
  python "$TMP_DIR/depixel.py" "$MOSAIC_BLOCK" "$in" "$out" "${REGIONS[@]}"
}

im_region_depixel() {
  local in="$1" out="$2"
  if [[ ${#IM_BIN[@]} -eq 0 ]]; then
    err "Cần ImageMagick để xử lý ảnh"
    return 1
  fi
  ensure_tmp
  local ext="png" cur="$in" n=0 r x y w h bw bh tmp
  [[ "$in" == *.* ]] && ext="${in##*.}"

  for r in "${REGIONS[@]}"; do
    read -r x y w h < <(parse_region "$r") || continue
    n=$((n + 1))
    bw=$(( w / MOSAIC_BLOCK )); (( bw < 1 )) && bw=1
    bh=$(( h / MOSAIC_BLOCK )); (( bh < 1 )) && bh=1
    tmp="$TMP_DIR/dp_$$_$n.$ext"
    if ! "${IM_BIN[@]}" "$cur" \
        \( +clone -crop "${w}x${h}+${x}+${y}" +repage \
           -resize "${bw}x${bh}!" -filter Cubic -resize "${w}x${h}!" \
           -blur 0x1.2 \) \
        -geometry "+${x}+${y}" -composite "$tmp" 2>>"$LOGFILE"; then
      err "ImageMagick lỗi ở vùng $r"
      return 1
    fi
    cur="$tmp"
  done

  if [[ "$cur" == "$in" ]]; then
    cp -- "$in" "$out" || return 1
  else
    mv -- "$cur" "$out" || return 1
  fi
}

finish_image() {
  local work="$1" out="$2" in="$3"
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
    return 0
  fi
  if [[ "$work" == "$in" ]]; then
    cp -- "$in" "$out" || return 1
  else
    mv -- "$work" "$out" || return 1
  fi
}

process_image_depixel() {
  local in="$1" out="$2"
  local work="$in" step="" ext="png"

  [[ -f "$in" ]] || { err "Không thấy file: $in"; return 1; }
  ensure_tmp
  [[ "$in" == *.* ]] && ext="${in##*.}"
  step="$TMP_DIR/dpx_$$.$ext"

  if (( ${#REGIONS[@]} == 0 )); then
    warn "Cần ít nhất 1 vùng mosaic"
    return 1
  fi

  if [[ "$MOSAIC_METHOD" == "fill" ]]; then
    if (( CV2_OK == 1 )); then
      python_inpaint "$in" "$step" || return 1
    else
      im_region_blur "$in" "$step" || return 1
    fi
  else
    if (( CV2_OK == 1 )); then
      if ! python_depixel "$in" "$step"; then
        warn "OpenCV lỗi, chuyển sang ImageMagick"
        step="$TMP_DIR/dpx_im_$$.$ext"
        im_region_depixel "$in" "$step" || return 1
      fi
    else
      im_region_depixel "$in" "$step" || return 1
    fi
  fi
  work="$step"

  finish_image "$work" "$out" "$in"
}

# ----------------------------- tự động phát hiện vùng mờ ---------------------
python_bin() {
  if command -v python >/dev/null 2>&1; then printf 'python'; return 0; fi
  if command -v python3 >/dev/null 2>&1; then printf 'python3'; return 0; fi
  return 1
}

have_python() {
  python_bin >/dev/null 2>&1
}

write_detect_helper() {
  ensure_tmp
  local py="$TMP_DIR/detect.py"
  [[ -f "$py" ]] && return 0
  cat >"$py" <<'PYDETECT'
#!/usr/bin/env python3
"""Phat hien vung mo / mosaic (pixel hoa) trong anh RGB raw.

    detect.py W H KIND raw1 [raw2 ...]

In ra moi dong mot vung: x:y:w:h. KIND: any | mosaic | blur
"""
import sys
from math import sqrt

CELL = 8
SEED_RATIO = 0.45
RING_R = 2
MIN_RING = 2.0
GROW_MAX = 6.0
MIN_AREA = 0.002
MAX_AREA = 0.25
MOSAIC_BLOCK = 2.2


def load_gray(path, w, h):
    with open(path, "rb") as fh:
        data = fh.read(w * h * 3)
    if len(data) < w * h * 3:
        raise SystemExit("raw khong du du lieu")
    gray = [0] * (w * h)
    for p in range(w * h):
        b = p * 3
        gray[p] = (data[b] + data[b + 1] + data[b + 2]) // 3
    return gray


def integral(a, w, h):
    ii = [0] * ((w + 1) * (h + 1))
    sw = w + 1
    for y in range(h):
        acc = 0
        row = y * w
        base = (y + 1) * sw
        up = y * sw
        for x in range(w):
            acc += a[row + x]
            ii[base + x + 1] = ii[up + x + 1] + acc
    return ii


def rect_sum(ii, w, x0, y0, x1, y1):
    sw = w + 1
    return (ii[y1 * sw + x1] - ii[y0 * sw + x1]
            - ii[y1 * sw + x0] + ii[y0 * sw + x0])


def cell_std(gray, w, h):
    cw = max(1, w // CELL)
    ch = max(1, h // CELL)
    out = [0.0] * (cw * ch)
    ii = integral(gray, w, h)
    ii2 = integral([v * v for v in gray], w, h)
    for cy in range(ch):
        y0 = cy * CELL
        y1 = min(h, y0 + CELL)
        for cx in range(cw):
            x0 = cx * CELL
            x1 = min(w, x0 + CELL)
            n = (y1 - y0) * (x1 - x0)
            m = rect_sum(ii, w, x0, y0, x1, y1) / n
            m2 = rect_sum(ii2, w, x0, y0, x1, y1) / n
            var = m2 - m * m
            out[cy * cw + cx] = sqrt(var) if var > 0 else 0.0
    return out, cw, ch


def ring_mean(std, cw, ch, r=RING_R):
    out = [0.0] * (cw * ch)
    for cy in range(ch):
        for cx in range(cw):
            total = 0.0
            n = 0
            for y in range(max(0, cy - r), min(ch, cy + r + 1)):
                base = y * cw
                for x in range(max(0, cx - r), min(cw, cx + r + 1)):
                    if x == cx and y == cy:
                        continue
                    total += std[base + x]
                    n += 1
            out[cy * cw + cx] = total / n if n else 0.0
    return out


def components(mask, cw, ch, min_cells=2):
    seen = [False] * (cw * ch)
    boxes = []
    for start in range(cw * ch):
        if not mask[start] or seen[start]:
            continue
        stack = [start]
        seen[start] = True
        minx = maxx = start % cw
        miny = maxy = start // cw
        count = 0
        while stack:
            cur = stack.pop()
            count += 1
            cx = cur % cw
            cy = cur // cw
            if cx < minx:
                minx = cx
            if cx > maxx:
                maxx = cx
            if cy < miny:
                miny = cy
            if cy > maxy:
                maxy = cy
            for ny in range(max(0, cy - 1), min(ch, cy + 2)):
                row = ny * cw
                for nx in range(max(0, cx - 1), min(cw, cx + 2)):
                    n = row + nx
                    if mask[n] and not seen[n]:
                        seen[n] = True
                        stack.append(n)
        if count >= min_cells:
            boxes.append((minx, miny, maxx, maxy, count))
    return boxes


def block_score(gray, w, x0, y0, x1, y1):
    span = x1 - x0 - 1
    if span < 8:
        return 0.0
    cols = [0.0] * span
    for y in range(y0, y1):
        row = y * w
        for x in range(x0, x0 + span):
            d = gray[row + x + 1] - gray[row + x]
            if d < 0:
                d = -d
            cols[x - x0] += d
    total = sum(cols) / len(cols) + 1e-9
    best = 0.0
    for b in range(4, 49):
        idx = list(range(b - 1, span, b))
        if len(idx) < 3:
            continue
        val = sum(cols[i] for i in idx) / len(idx)
        score = val / total
        if score > best:
            best = score
    return best


def inside_mean(std, cw, x0, y0, x1, y1):
    total = 0.0
    n = 0
    for y in range(y0, y1):
        base = y * cw
        for x in range(x0, x1):
            total += std[base + x]
            n += 1
    return total / n if n else 0.0


def iou(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    x0 = max(ax, bx)
    y0 = max(ay, by)
    x1 = min(ax + aw, bx + bw)
    y1 = min(ay + ah, by + bh)
    if x1 <= x0 or y1 <= y0:
        return 0.0
    inter = (x1 - x0) * (y1 - y0)
    return inter / float(aw * ah + bw * bh - inter)


def _near(a, b, gap=4):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return not (ax + aw + gap <= bx or bx + bw + gap <= ax
                or ay + ah + gap <= by or by + bh + gap <= ay)


def merge_boxes(boxes):
    boxes = list(boxes)
    changed = True
    while changed:
        changed = False
        n = len(boxes)
        for i in range(n):
            if boxes[i] is None:
                continue
            for j in range(i + 1, n):
                if boxes[j] is None:
                    continue
                if _near(boxes[i], boxes[j]):
                    a, b = boxes[i], boxes[j]
                    x0 = min(a[0], b[0])
                    y0 = min(a[1], b[1])
                    x1 = max(a[0] + a[2], b[0] + b[2])
                    y1 = max(a[1] + a[3], b[1] + b[3])
                    boxes[i] = (x0, y0, x1 - x0, y1 - y0)
                    boxes[j] = None
                    changed = True
        boxes = [b for b in boxes if b is not None]
    return boxes


def grow(seed_comp, std, cw, ch, thr):
    x0, y0, x1, y1, _ = seed_comp
    seen = set()
    stack = []
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            seen.add((x, y))
            stack.append((x, y))
    while stack:
        x, y = stack.pop()
        for ny in (y - 1, y, y + 1):
            if ny < 0 or ny >= ch:
                continue
            row = ny * cw
            for nx in (x - 1, x, x + 1):
                if nx < 0 or nx >= cw:
                    continue
                if (nx, ny) in seen:
                    continue
                if std[row + nx] < thr:
                    seen.add((nx, ny))
                    stack.append((nx, ny))
    xs = [p[0] for p in seen]
    ys = [p[1] for p in seen]
    return min(xs), min(ys), max(xs), max(ys)


def detect(raw_path, w, h, kind):
    gray = load_gray(raw_path, w, h)
    std, cw, ch = cell_std(gray, w, h)
    ring = ring_mean(std, cw, ch)

    seeds = [0] * (cw * ch)
    for i, v in enumerate(std):
        if ring[i] >= MIN_RING and v < SEED_RATIO * ring[i]:
            seeds[i] = 1

    comps = components(seeds, cw, ch, 2)
    boxes = []
    frame = float(w * h)

    for comp in comps:
        x0, y0, x1, y1, _ = comp
        ringmax = max(ring[y * cw + x]
                      for y in range(y0, y1 + 1)
                      for x in range(x0, x1 + 1))
        thr = max(0.8, min(0.7 * ringmax, GROW_MAX))
        gx0, gy0, gx1, gy1 = grow(comp, std, cw, ch, thr)

        bw = (gx1 - gx0 + 1) * CELL
        bh = (gy1 - gy0 + 1) * CELL
        area = (bw * bh) / frame
        if area < MIN_AREA or area > MAX_AREA:
            continue

        ins = inside_mean(std, cw, gx0, gy0, gx1 + 1, gy1 + 1)
        ox0 = max(0, gx0 - RING_R)
        oy0 = max(0, gy0 - RING_R)
        ox1 = min(cw, gx1 + RING_R + 1)
        oy1 = min(ch, gy1 + RING_R + 1)
        total = 0.0
        n = 0
        for yy in range(oy0, oy1):
            base = yy * cw
            for xx in range(ox0, ox1):
                if gx0 <= xx <= gx1 and gy0 <= yy <= gy1:
                    continue
                total += std[base + xx]
                n += 1
        out = total / n if n else 0.0

        if out < 2.0:
            continue

        if (bh > 0.7 * h and bw < 0.25 * w) or (bw > 0.7 * w and bh < 0.25 * h):
            continue

        x = gx0 * CELL
        y = gy0 * CELL
        bw = min(w - x, (gx1 - gx0 + 1) * CELL)
        bh = min(h - y, (gy1 - gy0 + 1) * CELL)

        score = block_score(gray, w, x, y, x + bw, y + bh)
        is_mosaic = score >= MOSAIC_BLOCK

        # Mosaic co luoi deu ro rang thi chap nhan ca khi tuong phan vien yeu.
        if is_mosaic:
            if out < ins * 1.05:
                continue
        else:
            if out < ins * 1.8:
                continue
            if ins < 0.5:
                continue

        if kind == "mosaic" and not is_mosaic:
            continue
        if kind == "blur" and is_mosaic:
            continue
        boxes.append((x, y, bw, bh))

    return merge_boxes(boxes)


def cluster(boxes, need):
    groups = []
    for box in boxes:
        placed = False
        for g in groups:
            if any(iou(box, other) >= 0.4 for other in g):
                g.append(box)
                placed = True
                break
        if not placed:
            groups.append([box])
    out = []
    for g in groups:
        if len(g) < need:
            continue
        xs = sorted(b[0] for b in g)
        ys = sorted(b[1] for b in g)
        xe = sorted(b[0] + b[2] for b in g)
        ye = sorted(b[1] + b[3] for b in g)
        mid = len(g) // 2
        x = xs[mid]
        y = ys[mid]
        out.append((x, y, xe[mid] - x, ye[mid] - y))
    return out


def main():
    if len(sys.argv) < 5:
        sys.stderr.write("usage: detect.py W H KIND raw...\n")
        return 2
    w = int(sys.argv[1])
    h = int(sys.argv[2])
    kind = sys.argv[3]
    raws = sys.argv[4:]

    sets = [detect(r, w, h, kind) for r in raws]
    if len(sets) == 1:
        boxes = sets[0]
    else:
        need = max(2, (len(sets) + 1) // 2)
        boxes = cluster([b for s in sets for b in s], need)

    for (x, y, bw, bh) in boxes:
        x = max(0, x - 2)
        y = max(0, y - 2)
        bw = min(w - x, bw + 4)
        bh = min(h - y, bh + 4)
        print("%d:%d:%d:%d" % (x, y, bw, bh))
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYDETECT
}

scale_dims() {
  local w="$1" h="$2" max="$3" dw dh
  if (( w <= max )); then
    printf '%s %s\n' "$w" "$h"
    return 0
  fi
  dw="$max"
  dh=$(( h * max / w ))
  (( dh < 16 )) && dh=16
  printf '%s %s\n' "$dw" "$dh"
}

scale_box_back() {
  local box="$1" W="$2" H="$3" dw="$4" dh="$5"
  local x y w h
  IFS=: read -r x y w h <<<"$box"
  x=$(( x * W / dw ))
  y=$(( y * H / dh ))
  w=$(( w * W / dw ))
  h=$(( h * H / dh ))
  (( x < 0 )) && x=0
  (( y < 0 )) && y=0
  (( x + w > W )) && w=$(( W - x ))
  (( y + h > H )) && h=$(( H - y ))
  (( w > 0 && h > 0 )) || return 1
  printf '%s:%s:%s:%s\n' "$x" "$y" "$w" "$h"
}

detect_regions_image() {
  local in="$1" kind="${2:-any}"
  local size W H dw dh raw py boxes
  local -a line found=()
  local scalar

  [[ -f "$in" ]] || return 1
  have_python || return 1
  detect_im
  [[ ${#IDENTIFY_BIN[@]} -gt 0 ]] || return 1

  size=$(probe_image_size "$in" 2>/dev/null) || return 1
  W="${size% *}"; H="${size#* }"
  [[ "$W" =~ ^[0-9]+$ && "$H" =~ ^[0-9]+$ ]] || return 1
  read -r dw dh < <(scale_dims "$W" "$H" "$DETECT_MAX_IMAGE")

  ensure_tmp
  write_detect_helper
  raw="$TMP_DIR/detect_img_$$.raw"
  "${IM_BIN[@]}" "${in}[0]" -resize "${dw}x${dh}!" -alpha off \
    -depth 8 -colorspace sRGB "rgb:$raw" 2>>"$LOGFILE" || return 1

  py=$(python_bin) || return 1
  boxes=$("$py" "$TMP_DIR/detect.py" "$dw" "$dh" "$kind" "$raw" 2>>"$LOGFILE") || return 1
  rm -f -- "$raw"

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    scalar=$(scale_box_back "$line" "$W" "$H" "$dw" "$dh") || continue
    [[ -n "$scalar" ]] && found+=("$scalar")
  done <<<"$boxes"

  (( ${#found[@]} > 0 )) || return 1
  printf '%s\n' "${found[@]}"
}

detect_regions_video() {
  local in="$1" kind="${2:-any}"
  local size W H dw dh dur t raw py boxes line
  local -a raws=() found=()
  local scalar

  [[ -f "$in" ]] || return 1
  have_python || return 1

  size=$(probe_video_size "$in") || return 1
  W="${size%x*}"; H="${size#*x}"
  [[ "$W" =~ ^[0-9]+$ && "$H" =~ ^[0-9]+$ ]] || return 1
  read -r dw dh < <(scale_dims "$W" "$H" "$DETECT_MAX_VIDEO")
  dur=$(probe_duration_ms "$in")

  ensure_tmp
  write_detect_helper

  local i
  for i in 1 2 3; do
    if (( dur > 0 )); then
      t=$(awk -v d="$dur" -v i="$i" 'BEGIN { printf "%.3f", (d / 1000) * i / 4 }')
    else
      t=0
    fi
    raw="$TMP_DIR/detect_v_$$_$i.raw"
    if ffmpeg -hide_banner -loglevel error -ss "$t" -i "$in" -frames:v 1 \
        -vf "scale=${dw}:${dh}:flags=lanczos" -f rawvideo -pix_fmt rgb24 -y "$raw" \
        >/dev/null 2>&1 && [[ -s "$raw" ]]; then
      raws+=("$raw")
    fi
  done

  if (( ${#raws[@]} == 0 )); then
    rm -f -- "$TMP_DIR"/detect_v_$$_*.raw
    return 1
  fi

  py=$(python_bin) || { rm -f -- "${raws[@]}"; return 1; }
  boxes=$("$py" "$TMP_DIR/detect.py" "$dw" "$dh" "$kind" "${raws[@]}" 2>>"$LOGFILE") || {
    rm -f -- "${raws[@]}"
    return 1
  }
  rm -f -- "${raws[@]}"

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    scalar=$(scale_box_back "$line" "$W" "$H" "$dw" "$dh") || continue
    [[ -n "$scalar" ]] && found+=("$scalar")
  done <<<"$boxes"

  (( ${#found[@]} > 0 )) || return 1
  printf '%s\n' "${found[@]}"
}

ask_regions_auto() {
  local kind="$1" path="$2"
  local -a found=()
  local r

  printf '%sCách xác định vùng:%s\n  1) Tự động phát hiện vùng mờ/mosaic (mặc định)\n  2) Nhập toạ độ thủ công\n' "$C_D" "$C_0"
  ask "Chọn" "1"
  if [[ "$REPLY" == "2" ]]; then
    ask_regions && return 0
    return 1
  fi

  if ! have_python; then
    warn "Cần python để tự động phát hiện: pkg install python"
    ask_regions && return 0
    return 1
  fi

  info "Đang phân tích ${path##*/} ..."
  if [[ "$kind" == "image" ]]; then
    mapfile -t found < <(detect_regions_image "$path")
  else
    mapfile -t found < <(detect_regions_video "$path")
  fi

  if (( ${#found[@]} == 0 )); then
    warn "Không phát hiện được vùng nào (ảnh test-card/đồ hoạ phẳng dễ bị bỏ sót)"
    ask_regions && return 0
    return 1
  fi

  REGIONS=("${found[@]}")
  info "Phát hiện ${#REGIONS[@]} vùng:"
  for r in "${REGIONS[@]}"; do
    printf '    %s\n' "$r"
  done

  if confirm "Dùng các vùng này?" "y"; then
    return 0
  fi
  REGIONS=()
  ask_regions && return 0
  return 1
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

# ----------------------------- khử mosaic/pixel (video) ----------------------
clamp_region_even() {
  local c x y w h
  c=$(clamp_region "$1" "$2" "$3") || return 1
  IFS=: read -r x y w h <<<"$c"
  x=$(( x - x % 2 )); y=$(( y - y % 2 ))
  w=$(( w - w % 2 )); h=$(( h - h % 2 ))
  (( w >= 4 && h >= 4 )) || return 1
  printf '%s:%s:%s:%s\n' "$x" "$y" "$w" "$h"
}

build_depixel_complex() {
  local -a regs=()
  local r c x y w h bw bh i n
  for r in "${REGIONS[@]}"; do
    if ! c=$(clamp_region_even "$r" "$FRAME_W" "$FRAME_H"); then
      warn "Bỏ qua vùng không hợp lệ: $r"
      continue
    fi
    regs+=("$c")
  done
  n=${#regs[@]}
  (( n > 0 )) || return 1

  local split_labels="" fc prev="s0"
  local soft=$(( MOSAIC_BLOCK / 8 ))
  (( soft < 1 )) && soft=1
  for ((i = 0; i <= n; i++)); do split_labels+="[s$i]"; done

  fc="[0:v]split=$((n + 1))${split_labels};"
  for ((i = 1; i <= n; i++)); do
    IFS=: read -r x y w h <<<"${regs[$((i - 1))]}"
    bw=$(( w / MOSAIC_BLOCK )); (( bw < 2 )) && bw=2
    bh=$(( h / MOSAIC_BLOCK )); (( bh < 2 )) && bh=2
    fc+="[s$i]crop=$w:$h:$x:$y,scale=$bw:$bh:flags=area,scale=$w:$h:flags=bicubic,boxblur=$soft:2[g$i];"
    fc+="[$prev][g$i]overlay=$x:$y:format=auto[o$i];"
    prev="o$i"
  done
  if [[ "$DO_DEBLUR" == "1" && -n "$UNSHARP_VID" ]]; then
    fc+="[$prev]unsharp=${UNSHARP_VID}[vout]"
  else
    fc+="[$prev]null[vout]"
  fi
  printf '%s' "$fc"
}

process_video_depixel() {
  local in="$1" out="$2"
  local size dur fc
  local -a cmd

  [[ -f "$in" ]] || { err "Không thấy file: $in"; return 1; }
  command -v ffmpeg >/dev/null 2>&1 || { err "Chưa cài ffmpeg"; return 1; }

  size=$(probe_video_size "$in")
  if [[ ! "$size" =~ ^[0-9]+x[0-9]+$ ]]; then
    err "Không đọc được kích thước video: $in"
    return 1
  fi
  FRAME_W="${size%x*}"
  FRAME_H="${size#*x}"

  if [[ "$MOSAIC_METHOD" == "fill" ]]; then
    if ! fc=$(build_video_filter); then
      warn "Không dựng được filter"
      return 1
    fi
    [[ -n "$fc" ]] || { warn "Không có vùng hợp lệ"; return 1; }
    dur=$(probe_duration_ms "$in")
    cmd=(ffmpeg -hide_banner -loglevel warning -y -i "$in"
         -vf "$fc" -map 0:v:0 -map '0:a?' -map_metadata 0
         -c:a copy -c:v libx264 -crf "$CRF" -preset "$X264_PRESET")
    case "$out" in
      *.mp4|*.mov|*.m4v) cmd+=(-movflags +faststart) ;;
    esac
    cmd+=("$out")
    info "Chế độ: lấp vùng (delogo) · filter: $fc"
    info "CRF=$CRF · preset=$X264_PRESET · audio copy"
    run_with_progress "$dur" "${cmd[@]}"
    return $?
  fi

  if ! fc=$(build_depixel_complex); then
    warn "Không có vùng mosaic hợp lệ (cần ≥ 4x4 px)"
    return 1
  fi
  dur=$(probe_duration_ms "$in")
  cmd=(ffmpeg -hide_banner -loglevel warning -y -i "$in"
       -filter_complex "$fc" -map '[vout]' -map '0:a?' -map_metadata 0
       -c:a copy -c:v libx264 -crf "$CRF" -preset "$X264_PRESET")
  case "$out" in
    *.mp4|*.mov|*.m4v) cmd+=(-movflags +faststart) ;;
  esac
  cmd+=("$out")
  info "Chế độ: làm mềm khối (block=$MOSAIC_BLOCK) · ${#REGIONS[@]} vùng"
  info "CRF=$CRF · preset=$X264_PRESET · audio copy"
  run_with_progress "$dur" "${cmd[@]}"
}

# ----------------------------- menu -----------------------------------------
ask_regions() {
  REGIONS=()
  printf '%sNhập vùng cần xử lý dạng x:y:w:h (Enter trống để kết thúc)%s\n' "$C_D" "$C_0"
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

ask_mosaic_method() {
  printf '%sPhương pháp xử lý vùng mosaic/pixel:%s\n' "$C_D" "$C_0"
  printf '  1) Làm mềm khối — giữ bố cục, giảm rõ vết pixel (mặc định)\n'
  printf '  2) Lấp vùng — inpaint/delogo lấy từ viền xung quanh\n'
  ask "Chọn" "1"
  case "$REPLY" in
    2) MOSAIC_METHOD="fill" ;;
    *) MOSAIC_METHOD="smooth" ;;
  esac
  ask "Kích thước khối mosaic (px)" "$MOSAIC_BLOCK"
  if is_number "$REPLY" && (( REPLY >= 2 )); then
    MOSAIC_BLOCK="$REPLY"
  fi
}

menu_depixel_image() {
  local in size base ext out
  ask "Đường dẫn ảnh" ""
  in=$(expand_path "$REPLY")
  [[ -f "$in" ]] || { err "Không thấy file: $in"; return 1; }

  size=$(probe_image_size "$in" 2>/dev/null) || size=""
  [[ -n "$size" ]] && info "Kích thước ảnh: ${size% *}x${size#* }"

  ask_regions_auto image "$in" || { err "Cần ít nhất 1 vùng"; return 1; }
  info "Sẽ xử lý ${#REGIONS[@]} vùng"
  ask_mosaic_method

  if confirm "Làm nét sau khi khử khối?" "n"; then DO_DEBLUR=1; else DO_DEBLUR=0; fi

  ask "Thư mục output" "$OUT_DIR"
  OUT_DIR=$(expand_path "$REPLY")
  mkdir -p "$OUT_DIR" || { err "Không tạo được $OUT_DIR"; return 1; }

  base="${in##*/}"; base="${base%.*}"
  ext="png"
  [[ "$in" == *.* ]] && ext="${in##*.}"
  out=$(unique_out "$OUT_DIR/${base}_depixel" "$ext")

  if process_image_depixel "$in" "$out"; then
    ok "Đã lưu: $out"
  else
    err "Xử lý ảnh thất bại"
  fi
}

menu_depixel_video() {
  local in size base ext out
  ask "Đường dẫn video" ""
  in=$(expand_path "$REPLY")
  [[ -f "$in" ]] || { err "Không thấy file: $in"; return 1; }

  size=$(probe_video_size "$in")
  [[ "$size" =~ ^[0-9]+x[0-9]+$ ]] || { err "Không đọc được video: $in"; return 1; }
  info "Kích thước video: ${size/x/ x } · $(( $(probe_duration_ms "$in") / 1000 )) giây"

  ask_regions_auto video "$in" || { err "Cần ít nhất 1 vùng"; return 1; }
  info "Sẽ xử lý ${#REGIONS[@]} vùng"
  ask_mosaic_method

  if confirm "Làm nét sau khi khử khối?" "n"; then DO_DEBLUR=1; else DO_DEBLUR=0; fi

  ask "Thư mục output" "$OUT_DIR"
  OUT_DIR=$(expand_path "$REPLY")
  mkdir -p "$OUT_DIR" || { err "Không tạo được $OUT_DIR"; return 1; }

  base="${in##*/}"; base="${base%.*}"
  ext="mp4"
  [[ "$in" == *.* ]] && ext="${in##*.}"
  out=$(unique_out "$OUT_DIR/${base}_depixel" "$ext")

  if process_video_depixel "$in" "$out"; then
    ok "Đã lưu: $out"
  else
    err "Xử lý video thất bại"
  fi
}

menu_batch() {
  local kind="$1" mode="${2:-clean}" dir outdir r f base ext out n=0 failed=0 auto=0
  local -a files=() exts=() list=() det=()
  local -A seen=()

  if [[ "$mode" == "ask" ]]; then
    printf '%sChế độ xử lý:%s\n  1) Xoá watermark + làm nét\n  2) Khử mosaic/pixel\n' "$C_D" "$C_0"
    ask "Chọn" "1"
    if [[ "$REPLY" == "2" ]]; then mode="depixel"; else mode="clean"; fi
  fi

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

  if [[ "$mode" == "depixel" ]]; then
    if have_python && confirm "Tự động phát hiện vùng cho từng file?" "n"; then
      auto=1
    fi
  fi

  if (( auto == 1 )); then
    REGIONS=()
    info "Sẽ tự phát hiện vùng cho từng file"
  elif ask_regions; then
    info "Áp dụng ${#REGIONS[@]} vùng cho tất cả file"
  else
    warn "Không có vùng nào, chỉ chạy làm nét"
  fi

  if [[ "$mode" == "depixel" ]]; then
    ask_mosaic_method
  fi

  if confirm "Làm nét sau khi xử lý?" "n"; then DO_DEBLUR=1; else DO_DEBLUR=0; fi

  ask "Thư mục output" "$dir/cleaned"
  outdir=$(expand_path "$REPLY")
  mkdir -p "$outdir" || { err "Không tạo được $outdir"; return 1; }

  local total=${#list[@]} suffix="_clean"
  [[ "$mode" == "depixel" ]] && suffix="_depixel"
  for f in "${list[@]}"; do
    n=$((n + 1))
    base="${f##*/}"; base="${base%.*}"
    ext="png"
    [[ "$f" == *.* ]] && ext="${f##*/}"; ext="${ext##*.}"
    out=$(unique_out "$outdir/${base}${suffix}" "$ext")
    printf '\n%s[%d/%d]%s %s\n' "$C_B" "$n" "$total" "$C_0" "${f##*/}"
    if [[ "$mode" == "depixel" ]] && (( auto == 1 )); then
      det=()
      if [[ "$kind" == "image" ]]; then
        mapfile -t det < <(detect_regions_image "$f")
      else
        mapfile -t det < <(detect_regions_video "$f")
      fi
      if (( ${#det[@]} == 0 )); then
        warn "Không phát hiện được vùng, bỏ qua file này"
        failed=$((failed + 1))
        continue
      fi
      REGIONS=("${det[@]}")
      info "Tự phát hiện ${#det[@]} vùng"
    fi
    if [[ "$kind" == "image" ]]; then
      if [[ "$mode" == "depixel" ]]; then
        process_image_depixel "$f" "$out" || { failed=$((failed + 1)); continue; }
      else
        process_image "$f" "$out" || { failed=$((failed + 1)); continue; }
      fi
    else
      if [[ "$mode" == "depixel" ]]; then
        process_video_depixel "$f" "$out" || { failed=$((failed + 1)); continue; }
      else
        process_video "$f" "$out" || { failed=$((failed + 1)); continue; }
      fi
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
    warn "Preset không có vùng nào"
  fi
  file="$PRESET_DIR/$name.conf"
  {
    printf '# preset %s · %s\n' "$name" "$(date '+%F %T')"
    printf 'WATERMARKS="%s"\n' "${REGIONS[*]}"
    printf 'UNSHARP_IMG="%s"\n' "$UNSHARP_IMG"
    printf 'UNSHARP_VID="%s"\n' "$UNSHARP_VID"
    printf 'CRF="%s"\n' "$CRF"
    printf 'INPAINT_RADIUS="%s"\n' "$INPAINT_RADIUS"
    printf 'MOSAIC_BLOCK="%s"\n' "$MOSAIC_BLOCK"
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
      MOSAIC_BLOCK) MOSAIC_BLOCK="$v" ;;
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
      MOSAIC_BLOCK) MOSAIC_BLOCK="$v" ;;
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
    printf 'MOSAIC_BLOCK="%s"\n' "$MOSAIC_BLOCK"
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
    printf '  6) Khối mosaic mặc định        : %s px\n' "$MOSAIC_BLOCK"
    printf '  7) Thư mục output mặc định     : %s\n' "$OUT_DIR"
    printf '  8) Lưu ra settings.conf\n  0) Quay lại\n'
    printf 'Chọn: '
    IFS= read -r c || return 0
    case "$c" in
      1) ask "CRF (0-51, thấp = nét hơn)" "$CRF"; is_number "$REPLY" && CRF="$REPLY" || warn "Giá trị không hợp lệ" ;;
      2) ask "x264 preset" "$X264_PRESET"; X264_PRESET="$REPLY" ;;
      3) ask "Unsharp ảnh" "$UNSHARP_IMG"; UNSHARP_IMG="$REPLY" ;;
      4) ask "Unsharp video" "$UNSHARP_VID"; UNSHARP_VID="$REPLY" ;;
      5) ask "Bán kính inpaint" "$INPAINT_RADIUS"; is_number "$REPLY" && INPAINT_RADIUS="$REPLY" || warn "Giá trị không hợp lệ" ;;
      6) ask "Khối mosaic (px)" "$MOSAIC_BLOCK"; is_number "$REPLY" && (( REPLY >= 2 )) && MOSAIC_BLOCK="$REPLY" || warn "Giá trị không hợp lệ" ;;
      7) ask "Thư mục output" "$OUT_DIR"; OUT_DIR=$(expand_path "$REPLY") ;;
      8) settings_save ;;
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

  if have_python; then
    ok "python (tự phát hiện vùng): có"
  else
    warn "python: không có → không dùng được --auto"
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
$APP_NAME $VERSION - xoá watermark & khử mosaic/pixel cho ảnh/video (Termux)

CÁCH DÙNG
  $APP_NAME                       mở menu tương tác
  $APP_NAME --check               kiểm tra phụ thuộc
  $APP_NAME --version             in phiên bản
  $APP_NAME image FILE [x:y:w:h ...] [--deblur] [--out DIR]
  $APP_NAME video FILE [x:y:w:h ...] [--deblur] [--out DIR] [--crf N]
  $APP_NAME depixel-image FILE [x:y:w:h ...] [--block N] [--fill] [--deblur]
  $APP_NAME depixel-video FILE [x:y:w:h ...] [--block N] [--fill] [--deblur]
  $APP_NAME depixel-image FILE --auto [--fill] [--block N]
  $APP_NAME depixel-video FILE --auto [--fill] [--block N]

VÍ DỤ
  $APP_NAME video clip.mp4 900:20:180:60 20:60:120:40
  $APP_NAME image logo.png 100:100:200:80 --deblur
  $APP_NAME depixel-video in.mp4 --auto
  $APP_NAME depixel-image face.png 120:80:200:200 --fill --deblur

GHI CHÚ
  - delogo chỉ hiệu quả với watermark tĩnh, cùng vị trí trên mọi frame.
  - Khử mosaic chỉ làm mềm cạnh khối hoặc lấp vùng; KHÔNG phục hồi chi tiết gốc.
  - Làm nét chỉ tăng tương phản cạnh, không tái tạo chi tiết đã mất.
  - --fill: lấp vùng bằng nội dung xung quanh (inpaint/delogo), mặc định là smooth.
  - --auto: tự phát hiện vùng mờ/mosaic (chỉ cần python, không cần thêm gói).
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
      --block)
        (( $# >= 2 )) || { err "--block cần giá trị"; return 2; }
        is_number "$2" && (( $2 >= 2 )) || { err "--block phải là số ≥ 2"; return 2; }
        MOSAIC_BLOCK="$2"; shift 2
        ;;
      --fill) MOSAIC_METHOD="fill"; shift ;;
      --smooth) MOSAIC_METHOD="smooth"; shift ;;
      --auto) AUTO_DETECT=1; shift ;;
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

  if [[ "$mode" == depixel-* ]] && (( AUTO_DETECT == 1 )) && (( ${#REGIONS[@]} == 0 )); then
    if ! have_python; then
      err "Tự động phát hiện cần python: pkg install python"
      return 1
    fi
    local -a det=()
    info "Đang tự phát hiện vùng mờ/mosaic ..."
    if [[ "$mode" == "depixel-image" ]]; then
      mapfile -t det < <(detect_regions_image "$f")
    else
      mapfile -t det < <(detect_regions_video "$f")
    fi
    if (( ${#det[@]} == 0 )); then
      err "Không phát hiện được vùng nào, hãy nhập toạ độ thủ công"
      return 1
    fi
    REGIONS=("${det[@]}")
    info "Phát hiện ${#REGIONS[@]} vùng:"
    local rr
    for rr in "${REGIONS[@]}"; do printf '    %s\n' "$rr"; done
  fi

  OUT_DIR="${outdir:-$OUT_DIR}"
  OUT_DIR=$(expand_path "$OUT_DIR")
  mkdir -p "$OUT_DIR" || { err "Không tạo được $OUT_DIR"; return 1; }

  local base ext out suffix="_clean"
  base="${f##*/}"; base="${base%.*}"
  ext="png"
  [[ "$f" == *.* ]] && ext="${f##*.}"
  case "$mode" in
    depixel-*) suffix="_depixel" ;;
  esac
  out=$(unique_out "$OUT_DIR/${base}${suffix}" "$ext")

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
    depixel-image)
      detect_im
      detect_cv2
      process_image_depixel "$f" "$out" && ok "Đã lưu: $out"
      ;;
    depixel-video)
      process_video_depixel "$f" "$out" && ok "Đã lưu: $out"
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
    printf '  1) Ảnh: xoá watermark + làm nét\n'
    printf '  2) Video: xoá watermark + làm nét\n'
    printf '  3) Ảnh: khử mosaic/pixel (blur dạng khối)\n'
    printf '  4) Video: khử mosaic/pixel (blur dạng khối)\n'
    printf '  5) Hàng loạt ảnh trong thư mục\n'
    printf '  6) Hàng loạt video trong thư mục\n'
    printf '  7) Xem trước / chọn toạ độ vùng\n'
    printf '  8) Preset\n'
    printf '  9) Kiểm tra & cài phụ thuộc\n'
    printf ' 10) Cài đặt mặc định\n'
    printf ' 11) Xem log gần nhất\n'
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
      3) menu_depixel_image; pause ;;
      4) menu_depixel_video; pause ;;
      5) menu_batch image ask; pause ;;
      6) menu_batch video ask; pause ;;
      7) menu_preview; pause ;;
      8) menu_presets ;;
      9) check_deps; pause ;;
      10) menu_settings ;;
      11) show_log; pause ;;
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
    image|video|depixel-image|depixel-video)
      cli_mode "$@"
      exit $?
      ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
