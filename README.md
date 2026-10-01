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

## Docs

- [docs/TECHNICAL.md](docs/TECHNICAL.md), what's actually patched and why
  (DirectWrite shaping, Unicode bidi L2 reordering, caret stops)
- [docs/UPDATE_SURVIVAL.md](docs/UPDATE_SURVIVAL.md), keeping the fix when Zed
  updates itself

`mirror-upstream.yml` polls Zed every 6 hours. When a new release lands it
bumps `UPSTREAM_REF` and a fresh build follows on its own. If the patch stops
applying to a newer Zed, the build fails loudly instead of shipping something
half-patched.

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

**نکته:** Zed خودش رو آپدیت می‌کنه و با این کار پچ می‌پره. یا
`"auto_update": false` رو توی `settings.json` خاموش کن، یا موقع پچ کردن
`-DisableAutoUpdate` بذار. بعد از هر آپدیت رسمی فقط کافیه پچر رو یه بار
دیگه اجرا کنی. بقیه‌اش رو [docs/UPDATE_SURVIVAL.md](docs/UPDATE_SURVIVAL.md)
گفتم.

**لایسنس:** همون لایسنس خود Zed (GPL-3.0).

</div>
