# rmblur · media_clean

Script menu cho **Termux** để xoá watermark tĩnh (logo, chữ ký) và làm nét ảnh/video bằng
`ffmpeg`, `ImageMagick` và `OpenCV` (tuỳ chọn). Không cần root, chạy tốt trên ARM64.

> **Phạm vi sử dụng:** chỉ dùng cho nội dung bạn sở hữu hoặc có quyền chỉnh sửa.
> Xoá watermark của nội dung do người khác tạo có thể vi phạm bản quyền và điều khoản dịch vụ.

---

## Tính năng

| Nhóm | Chức năng |
|------|-----------|
| Ảnh | Xoá watermark bằng inpaint (OpenCV TELEA) hoặc ImageMagick, làm nét bằng unsharp |
| Video | Xoá watermark bằng filter `delogo` của ffmpeg, làm nét bằng `unsharp`, giữ nguyên audio |
| Hàng loạt | Quét cả thư mục, báo tiến độ `[i/N]`, tổng kết thành công/lỗi |
| Hỗ trợ | Xem trước frame để lấy toạ độ, preset lưu/đọc/xoá, log từng lần chạy |
| CLI | Dùng được trong script khác, không cần menu |

---

## Yêu cầu

```bash
pkg update
pkg install -y ffmpeg imagemagick python
termux-setup-storage          # chỉ cần nếu xử lý file trong /sdcard
```

Tuỳ chọn (chất lượng inpaint tốt hơn ImageMagick):

```bash
pip install opencv-python-headless numpy
```

Kiểm tra nhanh:

```bash
./media_clean.sh --check
```

---

## Cài đặt

**Cách 1 · chạy tại chỗ**

```bash
git clone https://github.com/khahdihdz/rmblur.git
cd rmblur
chmod +x media_clean.sh
./media_clean.sh
```

**Cách 2 · cài vào PATH**

```bash
cd rmblur
bash install.sh          # copy vào $PREFIX/bin/media_clean
media_clean
```

**Cách 3 · tải 1 file**

```bash
curl -LO https://raw.githubusercontent.com/khahdihdz/rmblur/main/media_clean.sh
chmod +x media_clean.sh && ./media_clean.sh
```

---

## Menu

```
1) Xử lý 1 ảnh
2) Xử lý 1 video
3) Xử lý hàng loạt ảnh trong thư mục
4) Xử lý hàng loạt video trong thư mục
5) Xem trước / chọn toạ độ vùng watermark
6) Preset
7) Kiểm tra & cài phụ thuộc
8) Cài đặt mặc định
9) Xem log gần nhất
0) Thoát
```

Khi được hỏi vùng watermark, nhập `x:y:w:h` (pixel, gốc toạ độ là góc trên-trái).
Nhập nhiều vùng liên tiếp, Enter trống để kết thúc.

---

## CLI

```bash
media_clean image FILE [x:y:w:h ...] [--deblur] [--out DIR]
media_clean video FILE [x:y:w:h ...] [--deblur] [--out DIR] [--crf N]
media_clean --check
media_clean --help
```

Ví dụ:

```bash
# Xoá logo góc phải trên của clip dọc
media_clean video clip.mp4 900:20:180:60 --crf 20

# Nhiều vùng + làm nét
media_clean video in.mp4 940:12:180:60 20:60:120:40 --deblur --out ~/out

# Ảnh: xoá watermark rồi làm nét
media_clean image logo.png 100:100:200:80 --deblur
```

Output mặc định là `<tên>_clean.<ext>`, không bao giờ ghi đè file gốc.

---

## Lấy toạ độ vùng watermark

1. Menu → `5` → nhập đường dẫn file → chọn giây cần trích frame.
2. Mở ảnh `preview_*.png` bằng app xem ảnh (có hiển thị toạ độ pixel), hoặc dùng
   app chỉnh ảnh để đo vùng.
3. Nhập lại `x:y:w:h` khi xử lý.

Mẹo: chọn vùng **rộng hơn watermark 2–4px** mỗi phía. `delogo` nội suy từ viền xung quanh,
nên vùng sát mép khung hình sẽ cho kết quả kém.

---

## Preset

Preset lưu các vùng watermark + tham số làm nét + CRF:

```ini
# ~/.media_clean/presets/tiktok.conf
WATERMARKS="900:20:180:60"
UNSHARP_IMG="0x1.2+1.0+0.02"
UNSHARP_VID="5:5:1.0:5:5:0.0"
CRF="23"
INPAINT_RADIUS="7"
```

Repo có sẵn vài preset mẫu trong `presets/` (được `install.sh` copy vào
`~/.media_clean/presets/`). **Toạ độ là pixel tuyệt đối**, nên phải chỉnh lại theo độ phân giải.

---

## Cài đặt mặc định

Menu → `8`, hoặc sửa trực tiếp `~/.media_clean/settings.conf`:

| Khoá | Mặc định | Ý nghĩa |
|------|----------|---------|
| `CRF` | `23` | Chất lượng video, thấp = nét hơn, file lớn hơn |
| `X264_PRESET` | `medium` | Tốc độ encode của x264 |
| `UNSHARP_IMG` | `0x1.2+1.0+0.02` | Làm nét ảnh |
| `UNSHARP_VID` | `5:5:1.0:5:5:0.0` | Làm nét video |
| `INPAINT_RADIUS` | `7` | Bán kính inpaint khi xoá watermark ảnh |
| `OUT_DIR` | `$PWD/output` | Thư mục output mặc định |

---

## Troubleshooting

| Lỗi | Cách xử lý |
|-----|-----------|
| `Permission denied` khi đọc `/sdcard` | chạy `termux-setup-storage`, cấp quyền |
| `Unknown encoder 'libx264'` | `pkg install -y ffmpeg`, tránh bản build thiếu x264 |
| `delogo` báo lỗi vùng | vùng phải nằm trong khung, cách mép ≥ 1px; script tự kẹp nhưng nên chọn lại |
| Hết RAM với video 4K | giảm `-preset` (đã đặt `medium`), cắt clip ngắn hơn, hoặc xử lý từng đoạn |
| `python: No module named cv2` | `pip install opencv-python-headless` hoặc để script fallback sang ImageMagick |
| Ảnh ra bị nhoè cả vùng lớn | vùng watermark chọn quá rộng, hoặc dùng `INPAINT_RADIUS` nhỏ hơn (3–5) |
| Video bị mất phụ đề | script chỉ map video + audio; track phụ đề không được copy |

Log từng lần chạy: `~/.media_clean/logs/`.

---

## Giới hạn kỹ thuật (quan trọng)

- **`delogo` chỉ dùng cho watermark tĩnh**, cùng vị trí trên mọi frame. Watermark chạy/di chuyển
  cần tracking riêng, script này không làm.
- **Không thể phục hồi ảnh bị blur thật.** `unsharp` chỉ tăng tương phản cạnh; chi tiết đã mất
  thì không tái tạo được.
- Vùng bị **mosaic/pixelate** chỉ có thể inpaint — kết quả là nội dung được "đoán", thường nhoè.
- `delogo` phải re-encode video; không thể `-c:v copy` mà vẫn xoá được watermark.

---

## Cấu trúc

```
media_clean.sh          script chính (menu + CLI)
install.sh              cài vào $PREFIX/bin và copy preset mẫu
presets/*.conf          preset mẫu
LICENSE                 MIT
```

---

## License

MIT © 2026 khahdihdz
