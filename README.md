# Zed RTL: RTL/Persian text fix for Zed on Windows

Zed on Windows draws right-to-left text broken. Letters don't join, words come
out backwards, the caret ends up in the wrong place. This repo fixes it and
ships Windows builds you can just run.

The fix is in the text-shaping layer, so it works everywhere Zed draws text:
editor, terminal pane, remote sessions.

## Downloads

All of it is on the [releases page](https://github.com/AmirAliManzar/Zed-RTL/releases):

- `zed-rtl-x86_64.exe`, portable Zed build, 64-bit Intel/AMD
- `zed-rtl-aarch64.exe`, same thing for Windows on ARM
- `zed-rtl-patcher-x86_64.exe` / `zed-rtl-patcher-aarch64.exe`, the one-click
  patcher (asks for admin, swaps your installed Zed for the fixed one)
- `zed-rtl.patch`, just the patch, if you build Zed yourself

The Zed builds are portable. No installer, no admin prompt, they read your
existing settings from `%APPDATA%\Zed`. Double-click and you're in.

## Replacing your installed Zed

Run the patcher exe above (it pops a UAC prompt), or from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\patch-zed.ps1
```

Both back up your current `Zed.exe`, download the build matching your installed
version, and swap it in. Useful switches: `-DisableAutoUpdate` so an official
update doesn't quietly undo the fix, `-Revert` to put the original back, and
`-ZedExe <path>` to patch a Zed somewhere else.

## Surviving official Zed updates

Zed's auto-updater replaces `Zed.exe` wholesale, so any exe-level fix is erased
the moment an update lands. There is no smaller file to patch: Zed is a single
statically-linked exe, the rendering code is compiled into it, and extensions
run sandboxed and cannot touch text shaping.

Two practical ways to keep the fix:

1. Patch once and turn auto-update off
   (`patch-zed.ps1 -DisableAutoUpdate`). The fix stays forever, but you stop
   getting official updates until you update manually and re-patch.
2. Keep auto-update on and re-run the patcher after each update. It is a
   double-click, about 5 seconds, no reinstall, no admin rights; it fetches
   the build matching your new version from Releases. Your settings and
   extensions are never touched.

The `mirror-upstream` job here polls Zed every 6 hours and rebuilds for each
new official version, so the patcher always finds a match.

The real fix is upstream: once this lands in `zed-industries/zed`, every
official build renders Persian/RTL correctly out of the box and none of this
is needed anymore.

## Building it yourself

```powershell
# x64
powershell -ExecutionPolicy Bypass -File .\scripts\build-and-deploy.ps1
# ARM64
powershell -ExecutionPolicy Bypass -File .\scripts\build.patched.ps1 -Target aarch64-pc-windows-msvc
```

You need Rust, the MSVC build tools and CMake. The script installs the Rust
channel Zed pins. Takes about an hour on 4 cores. `UPSTREAM_REF` says which Zed
version gets patched.

If you want to read what the patch actually does and why, the explanations live
as comments in the patched sources themselves:
`crates/gpui_windows/src/direct_write.rs` (glyph and run reordering) and
`crates/gpui/src/text_system/line_layout.rs` (caret stops). The whole change is
`patch/zed-rtl.patch`, and `patch/direct_write.rs` is a readable reference copy
of the patched Windows shaper.

## License

Same as Zed: **GPL-3.0**. [LICENSE](LICENSE) is copied from Zed itself. The two
crates the patch touches (`gpui`, `gpui_windows`) are Apache-2.0 upstream, see
[LICENSE-APACHE](LICENSE-APACHE), which is compatible. A downloaded `zed.exe`
is a modified Zed and carries Zed's own license terms.

## Credit

The approach builds on [zed PR #60115](https://github.com/zed-industries/zed/pull/60115).
The proper home for this fix is upstream. This repo is the stopgap until then.

---

<div dir="rtl" align="right">

## فارسی

Zed توی ویندوز متن فارسی/عربی/عبری رو خراب نشون می‌ده: حروف از هم جدا میشن،
کلمات برعکس میشن و کرسر هم یه جای دیگه می‌افته. این ریپو هم مشکل رو حل می‌کنه
هم بیلد آماده‌اش رو داره.

**چیا درست شده:**
- اتصال حروف، یعنی shaping درست برای فارسی/عربی/عبری
- ترتیب کلمات، حتی تو خطوطی که فارسی و انگلیسی قاطی شدن
- حرکت کرسر و کلیک روی متن فارسی
- خطوطی که فقط انگلیسی یا عددن، دست‌نخورده موندن

**چطور استفاده کنی:**
- `zed-rtl-x86_64.exe` رو (یا `zed-rtl-aarch64.exe` اگه ARM داری) از
  [releases](https://github.com/AmirAliManzar/Zed-RTL/releases) بگیر و
  دابل‌کلیک کن. نصبی نیست و تنظیمات Zed خودت رو می‌خونه.
- اگه می‌خوای Zedِ نصب‌شده عوض بشه: پچر `zed-rtl-patcher-x86_64.exe` رو اجرا
  کن (خودش دسترسی ادمین می‌خواد)، یا تو PowerShell این رو بزن:
  `powershell -ExecutionPolicy Bypass -File scripts\patch-zed.ps1`
  از Zed فعلی بک‌آپ می‌گیره و نسخه‌ی درست رو جاش می‌ذاره. با `-Revert` هم
  برمی‌گردی به حالت اول.

**آپدیت رسمی و پچ:** آپدیت خودکار Zed کل `Zed.exe` رو عوض می‌کنه و پچ رو
پاک می‌کنه. جایگزین کردن یه فایل کوچیک (مثل یه dll) هم **اصلاً ممکن نیست**،
چون Zed یه exeی تک‌پارچه‌ست و کد رندرینگ متن توی خودش کامپایل شده. دو تا راه
داری:
1. یه بار پچ کن و آپدیت خودکار رو خاموش کن (`-DisableAutoUpdate`). تا ابد
   سر جاش می‌مونه، ولی آپدیت رسمی نمیگیری تا خودت دستی آپدیت کنی.
2. آپدیت خودکار روشن بمونه و بعد از هر آپدیت یه بار پچر رو دوباره اجرا کنی.
   همون دابل‌کلیکه، ۵ ثانیه طول می‌کشه، نیازی به نصب دوباره یا دسترسی ادمین
   نداره. تنظیمات و اکستنشن‌ها دست‌نخورده می‌مونن.

ریپو هر ۶ ساعت یه بار Zed رو چک می‌کنه و برای هر نسخه‌ی جدید بیلد می‌گیره،
پس پچر همیشه نسخه‌ی متناسب پیدا می‌کنه.

راه حل واقعی اینه که این پچ توی خود Zed مرج بشه؛ اونوقت هیچ کدوم از اینا
دیگه لازم نیست.

**برای توسعه‌دهنده:** اگه می‌خوای بدونی پچ دقیقاً چیکار می‌کنه و چرا،
توضیحاتش رو به شکل کامنت توی خود سورس‌ها گذاشتم:
`crates/gpui_windows/src/direct_write.rs` (مرتب‌سازی حروف و runها) و
`crates/gpui/src/text_system/line_layout.rs` (مختصات کرسر). کل تغییر
`patch/zed-rtl.patch` هست و `patch/direct_write.rs` یه کپی خوانا از شِیپر
ویندوزِ پچ‌شده.

**لایسنس:** همون لایسنس خود Zed (GPL-3.0).

</div>
