# Zed RTL — Persian / RTL text rendering fix for Zed on Windows

<div dir="rtl" align="right">

**اصلاح رندر شدن متن فارسی/راست‌به‌چپ در Zed روی ویندوز** — نسخه‌ی پچ‌شده و کاملاً تست‌شده.

</div>

Zed (the code editor) renders right-to-left scripts — Persian, Arabic, Hebrew — **garbled on Windows**: letters disconnected, words reversed (`سلام خوبی؟` shows as `خوبی؟ سلام`), and the caret/cursor doesn't move correctly through RTL text. This repo fixes it at the text-shaping level and publishes ready-to-use Windows builds.

**Status:** working and verified on Persian text — letter joining, word order, **and caret movement / click positioning** (mixed Persian/English lines included). English-only lines are completely untouched (zero behavioral change).

---

## ⬇️ Download

| Build | Link |
|---|---|
| Rolling build (latest from `main`) | [zed-rtl-x86_64.exe](https://github.com/amiralimanzar/zed-rtl/releases/download/rolling/zed-rtl-x86_64.exe) |
| All releases | [releases](https://github.com/amiralimanzar/zed-rtl/releases) |

The `.exe` is a **fully portable** Zed build: no installer, no admin rights. It reads your existing Zed settings from `%APPDATA%\Zed`. Requirements: **Windows 10/11, x64**.

## 🚀 Use it

### Option 1 — just run it (no install, portable)
Download the exe above, put it anywhere (e.g. `Desktop`), double-click. Done. Nothing else is touched. To keep it as your everyday Zed, see Option 2.

### Option 2 — replace your installed Zed (one-click patcher)

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\patch-zed.ps1
```

This script:
1. finds your installed Zed (`%LOCALAPPDATA%\Programs\Zed\Zed.exe`),
2. **backs it up** to `Zed.exe.bak-<version>`,
3. downloads the matching patched build from this repo's Releases,
4. swaps it in.

Optional switches: `-DisableAutoUpdate` (so official updates don't silently revert the fix — see [docs/UPDATE_SURVIVAL.md](docs/UPDATE_SURVIVAL.md)), `-Revert` (restore the backup), `-ZedExe <path>`.

> ℹ️ Builds **track the latest stable Zed** (currently `v1.21.0`, matching the same version Zed auto-installs). The patch was developed and visually verified against the `1.12.0`-era tree and applies with byte-identical context to newer tags, so a `1.21` build behaves the same. The patcher only warns if your installed version differs from the built one.

## 🛠️ Build from source

```powershell
# clones upstream Zed at the pinned commit, applies the patch, builds release
powershell -ExecutionPolicy Bypass -File .\scripts\build-and-deploy.ps1
```
Requires: Rust 1.95.0 (installed automatically by the script via rustup), MSVC build tools, CMake. Build takes ~60–90 min on 4–8 cores.

## 📖 Documentation

- **[docs/UPDATE_SURVIVAL.md](docs/UPDATE_SURVIVAL.md)** — *how to keep the fix across official Zed updates without installing a third-party app every time* (your main question, answered in detail — in Persian and English).
- **[docs/TECHNICAL.md](docs/TECHNICAL.md)** — what exactly is patched and why it works (Unicode bidi L2 + per-run glyph reordering).

## 🔁 Keeping builds fresh

`mirror-upstream.yml` runs **every 6 hours**: if upstream Zed published a new release tag, it bumps `UPSTREAM_REF` and pushes — which triggers a fresh build + rolling release automatically. The build script reads its toolchain from upstream's `rust-toolchain.toml`, so it adapts when Zed bumps its Rust version. If the patch no longer applies to a newer Zed (the file changed upstream), the build fails loudly and an issue is the cue to refresh `patch/zed-rtl.patch`.

## 📄 License

- This repo's code (patch + scripts + workflows): **Apache-2.0** — matching the license of `gpui_windows`, the crate we patch.
- **The built `zed.exe` is a modified Zed and inherits Zed's own license (GPL-3.0 with Zed's additional terms).** By downloading a build you accept those terms. See [zed-industries/zed](https://github.com/zed-industries/zed).

## 🙏 Credit / upstream

The final fix was developed by debugging and iterating on the approach from [zed PR #60115](https://github.com/zed-industries/zed/pull/60115). The **real long-term home for this fix is upstream** — see `docs/UPDATE_SURVIVAL.md` Option D.

---

<div dir="rtl" align="right">

## فارسی — خلاصه

- **مشکل:** Zed روی ویندوز متن فارسی/عبری/عربی را خراب نشان می‌داد (حروف جدا، جابه‌جایی کلمات).
- **راه‌حل:** اصلاح دو بخش در موتور رندر متن (DirectWrite shaping): ترتیب حروف داخل هر کلمه + الگوریتم L2 یونیکد برای ترتیب کلمات.
- **استفاده:** یا فقط `zed-rtl-x86_64.exe` را دانلود کن و اجرا کن (نیازی به نصب نیست، پرتاببل است)، یا با `scripts/patch-zed.ps1` جایگزین Zed نصب‌شده کن.
- **سؤال آپدیت رسمی:** پاسخ کامل در [docs/UPDATE_SURVIVAL.md](docs/UPDATE_SURVIVAL.md). خلاصه: راه اصولی و دائمی فقط **پذیرفته شدن upstream** است؛ در غیر این صورت، یا آپدیت خودکار را خاموش کن یا بعد از هر آپدیت یک کلیک دوباره پچ کن.
- **انگلیسی خالص:** هیچ تغییری نمی‌کند (کد فقط وقتی فعال می‌شود که متن RTL داشته باشی).

</div>
