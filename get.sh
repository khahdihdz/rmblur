#!/data/data/com.termux/files/usr/bin/bash
# Cài rmblur/media_clean trực tiếp từ GitHub, không cần git clone.
#   curl -fsSL https://raw.githubusercontent.com/khahdihdz/rmblur/main/get.sh | bash
set -euo pipefail

REPO="${MEDIA_CLEAN_REPO:-khahdihdz/rmblur}"
REF="${MEDIA_CLEAN_REF:-main}"
BASE="https://raw.githubusercontent.com/$REPO/$REF"
BIN_DIR="${PREFIX:-$HOME/.local}/bin"
TARGET="$BIN_DIR/media_clean"
STATE_DIR="${MEDIA_CLEAN_HOME:-$HOME/.media_clean}"
PRESET_DIR="$STATE_DIR/presets"

if [[ -z "${PREFIX:-}" ]]; then
  echo "[!] Script này dành cho Termux (biến PREFIX chưa được set)." >&2
  echo "    Trên Linux thường, hãy clone repo và chạy: bash install.sh" >&2
  exit 1
fi

command -v curl >/dev/null 2>&1 || { echo "[!] Cần curl: pkg install curl" >&2; exit 1; }

TMP_DIR=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/rmblur.XXXXXX")
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

echo "[*] Tải media_clean.sh từ $REPO@$REF"
curl -fsSL "$BASE/media_clean.sh" -o "$TMP_DIR/media_clean.sh"

mkdir -p "$BIN_DIR" "$PRESET_DIR"
install -m 755 "$TMP_DIR/media_clean.sh" "$TARGET"
echo "[+] Đã cài: $TARGET"

copied=0
for p in tiktok youtube light_deblur strong_deblur; do
  if [[ -e "$PRESET_DIR/$p.conf" ]]; then
    echo "[=] Giữ nguyên preset: $p.conf"
    continue
  fi
  if curl -fsSL "$BASE/presets/$p.conf" -o "$PRESET_DIR/$p.conf" 2>/dev/null; then
    copied=$((copied + 1))
  else
    echo "[!] Không tải được preset $p"
  fi
done
echo "[+] Preset mẫu: $copied mới → $PRESET_DIR"

missing=()
command -v ffmpeg  >/dev/null 2>&1 || missing+=(ffmpeg)
command -v ffprobe >/dev/null 2>&1 || missing+=(ffmpeg)
if ! command -v magick >/dev/null 2>&1 && ! command -v convert >/dev/null 2>&1; then
  missing+=(imagemagick)
fi

if (( ${#missing[@]} > 0 )); then
  echo "[!] Thiếu: ${missing[*]}"
  echo "    pkg install -y ${missing[*]}"
else
  echo "[+] Đủ phụ thuộc cơ bản"
fi

echo
echo "Chạy: media_clean"
