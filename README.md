# Zed RTL

A Windows patch that fixes right-to-left text rendering in [Zed](https://github.com/zed-industries/zed).

On Windows, Zed currently has problems rendering Persian, Arabic, and Hebrew text. Characters may appear disconnected, words may be displayed in the wrong order, and the caret may be placed incorrectly.

This patch fixes the problem at the text-shaping layer, so it applies wherever Zed renders text, including:

- The editor
- The terminal
- Remote sessions

## Downloads

Prebuilt files are available on the [Releases](../../releases) page:

- `zed-rtl-x86_64.exe` — Portable build for 64-bit Intel/AMD systems
- `zed-rtl-aarch64.exe` — Portable build for Windows on ARM
- `zed-rtl-patcher-x86_64.exe` — Patcher for x86_64 installations
- `zed-rtl-patcher-aarch64.exe` — Patcher for ARM64 installations
- `zed-rtl.patch` — The patch for building Zed yourself

The portable builds do not require installation or administrator access. They use your existing Zed configuration from:

```text
%APPDATA%\Zed
```

Download the version that matches your system and run it.

## Patching an Existing Installation

To patch an installed copy of Zed, run the patcher for your system architecture.

The patcher:

1. Creates a backup of your current `Zed.exe`
2. Downloads the build that matches your installed Zed version
3. Replaces the original executable with the patched one

You can also run the patcher from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\patch-zed.ps1
```

Useful options:

```powershell
# Disable automatic updates
powershell -ExecutionPolicy Bypass -File .\scripts\patch-zed.ps1 -DisableAutoUpdate

# Restore the original executable
powershell -ExecutionPolicy Bypass -File .\scripts\patch-zed.ps1 -Revert

# Use a custom Zed executable
powershell -ExecutionPolicy Bypass -File .\scripts\patch-zed.ps1 -ZedExe "C:\Path\To\Zed.exe"
```

## Zed Updates

Zed's updater replaces the entire `Zed.exe` file. As a result, an official update removes the patch.

There is no separate DLL that can be replaced instead: Zed is distributed as a single statically linked executable, and the text-rendering code is compiled into it.

You have two options:

1. Disable automatic updates and update Zed manually when needed.
2. Keep automatic updates enabled and run the patcher again after each update.

The patcher downloads the build corresponding to your installed Zed version. Your settings and extensions are not affected.

This repository checks for new Zed releases every six hours and builds a matching patched version when needed.

## Building from Source

Requirements:

- Rust
- MSVC build tools
- CMake

Build the x64 version:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-and-deploy.ps1
```

Build the ARM64 version:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build.patched.ps1 -Target aarch64-pc-windows-msvc
```

The build script installs the Rust toolchain pinned by Zed. A build typically takes about an hour on a four-core machine.

The Zed version being patched is specified by `UPSTREAM_REF`.

## Implementation Details

The patch changes two parts of Zed:

- `crates/gpui_windows/src/direct_write.rs`  
  Glyph shaping and text-run reordering on Windows

- `crates/gpui/src/text_system/line_layout.rs`  
  Caret and cursor positions

The complete patch is available at:

```text
patch/zed-rtl.patch
```

A readable copy of the patched Windows text shaper is available at:

```text
patch/direct_write.rs
```

The implementation keeps lines containing only English text or numbers unchanged.

## Status

This repository is a temporary solution until proper RTL support is merged into Zed itself.

The approach is based on the work discussed in [Zed PR #60115](https://github.com/zed-industries/zed/pull/60115).

## License

This project uses the same GPL-3.0 license as Zed. The license text is included in `LICENSE`.

The two upstream crates modified by this patch, `gpui` and `gpui_windows`, are licensed under Apache-2.0. See `LICENSE-APACHE` for the applicable license text.

Downloaded Zed binaries are modified versions of Zed and remain subject to Zed's license terms.

---

## فارسی

این پروژه مشکل نمایش متن‌های راست‌به‌چپ، به‌ویژه فارسی، عربی و عبری، رو در نسخهٔ ویندوز Zed برطرف می‌کنه.

برای استفاده، نسخهٔ مناسب سیستم خودتون رو از بخش [Releases](../../releases) دانلود کنید. فایل‌های پورتابل نیازی به نصب ندارند و تنظیمات فعلی Zed رو حفظ می‌کنن.

اگه Zed روی سیستمتون نصبه، می‌توانید با استفاده از Patcher یا اسکریپت PowerShell فایل اجراییش رو اصلاح کنید؛ پس از هر به‌روزرسانی رسمی Zed، لازمه Patcher دوباره اجرا شود؛ چون به‌روزرسانی، فایل اجرایی قبلی رو جایگزین می‌کنه.

این پروژه راه‌حلی موقته تا پشتیبانی کامل از متن‌های راست‌به‌چپ مستقیماً به Zed اضافه بشه.

### مجوز

این پروژه تحت مجوز GPL-3.0 منتشر می‌شود. دو بخش اصلاح‌شدهٔ Zed، یعنی `gpui` و `gpui_windows`، در پروژهٔ اصلی تحت مجوز Apache-2.0 قرار دارند. متن کامل مجوزها در فایل‌های `LICENSE` و `LICENSE-APACHE` موجود است.
