#!/data/data/com.termux/files/usr/bin/bash
# Cài media_clean.sh vào $PREFIX/bin và copy preset mẫu.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
TARGET="$BIN_DIR/media_clean"
STATE_DIR="${MEDIA_CLEAN_HOME:-$HOME/.media_clean}"
PRESET_DIR="$STATE_DIR/presets"

if [[ ! -f "$SCRIPT_DIR/media_clean.sh" ]]; then
  echo "Không thấy media_clean.sh trong $SCRIPT_DIR" >&2
  exit 1
fi

mkdir -p "$BIN_DIR" "$PRESET_DIR"
install -m 755 "$SCRIPT_DIR/media_clean.sh" "$TARGET"
echo "[+] Đã cài: $TARGET"

if [[ -d "$SCRIPT_DIR/presets" ]]; then
  copied=0
  for f in "$SCRIPT_DIR"/presets/*.conf; do
    [[ -f "$f" ]] || continue
    if [[ -e "$PRESET_DIR/${f##*/}" ]]; then
      echo "[=] Giữ nguyên preset đã có: ${f##*/}"
    else
      cp "$f" "$PRESET_DIR/"
      copied=$((copied + 1))
    fi
  done
  echo "[+] Preset mẫu đã copy: $copied → $PRESET_DIR"
fi

missing=()
command -v ffmpeg   >/dev/null 2>&1 || missing+=("ffmpeg")
command -v ffprobe  >/dev/null 2>&1 || missing+=("ffmpeg")
command -v magick   >/dev/null 2>&1 || command -v convert >/dev/null 2>&1 || missing+=("imagemagick")

if (( ${#missing[@]} > 0 )); then
  echo "[!] Thiếu: ${missing[*]}"
  echo "    pkg install -y ${missing[*]}"
else
  echo "[+] Đủ phụ thuộc cơ bản"
fi

echo
echo "Chạy: media_clean"
