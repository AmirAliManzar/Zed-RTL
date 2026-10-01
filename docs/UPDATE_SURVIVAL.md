# Keeping the fix across official Zed updates

<div dir="rtl" align="right">

این دقیقاً همان سؤالی است که پرسیدی: *«آیا راهی هست بدون اینکه آپدیت رسمی Zed رو از دست بدم و هر بار لازم نباشه برنامه‌ی شخص ثالث نصب کنم، با patcher یا جایگزین فایل خاصی این مشکل رو حل کنم؟»*

**پاسخ کوتاه و صادقانه:** دو جواب واقعی وجود دارد: یکی موقت/عملی، یکی دائمی. اما **«جایگزین کردن یک فایل کوچک خاص» امکانش نیست** (دلیلش پایین). بیاید اول ببینیم چرا.

</div>

---

## Why a tiny file-swap / mini-patcher is impossible

Zed on Windows is a single statically-linked Rust executable. The RTL bug
lives in the crate `gpui_windows`, which is compiled **into `Zed.exe`**.
There is no separate `renderer.dll` or `text-engine.dll` to replace, unlike
Electron/CEF-based editors. Zed *extensions* run in a sandbox and cannot
touch the editor's core text rendering.

So the only file you can touch is `Zed.exe` itself, and the patched build is
a full Zed. That's why this repo ships a complete (portable) `zed.exe`;
there is no smaller artifact to ship.

## Why official updates break any exe-level fix

Zed's auto-updater **replaces `Zed.exe` wholesale** on every update. Any
change you make to that file, ours or a byte-patch, is erased the moment an
official update lands. This is inherent, not a flaw in our approach.

---

## Option A: one-time patch + disable auto-update (simplest)

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\patch-zed.ps1 -DisableAutoUpdate
```

The fix stays forever. You keep your settings, extensions, everything.
**Trade-off:** you stop receiving official updates (security patches, new
features) until you manually update. To update: update Zed normally, then
re-run the patcher (it fetches the build matching your new version).

## Option B: one-click re-patch after each update (recommended middle ground)

Keep auto-update **on**. After Zed updates, the fix is gone, so you just
double-click `patch-zed.ps1` again (about 5 seconds, no reinstall, no admin
rights, it re-downloads the matching build from Releases). This is
"re-patch, not re-install": no third-party app, no setup, your Zed profile
is untouched. This repo's weekly `mirror-upstream` job keeps patched builds
available for each new official version, so the patcher always finds a match.

## Option C: fully automatic self-healing (zero-touch)

A Windows scheduled task runs `patch-zed.ps1 -Silent` at every login. It
detects that the installed `Zed.exe` is no longer the patched build
(the version string / our marker changed), silently re-downloads the
matching patched build and swaps it in. You never think about it again.

Install it with one command (documented here; script provided on request):

```powershell
schtasks /Create /TN "ZedRTL-Heal" /SC ONLOGON /RL LIMITED `
  /TR "powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Tools\patch-zed.ps1 -Silent"
```

**Trade-off:** a small background step runs at login, and it auto-downloads
binaries from this repo, so you must trust the repo's releases. (Use a
scheduled-task PIN or review `-Silent` behavior before enabling.)

## Option D: upstream it (THE permanent fix)

The only solution that **survives official updates by design** and needs
**zero** third-party anything: get this fix merged into
`zed-industries/zed`. Then every official Zed, including every auto-update,
renders Persian/RTL correctly out of the box.

This patch is small, well-isolated, and ships with CI proof that it builds
cleanly. The natural next step:

1. Open an issue on `zed-industries/zed` titled *"Windows: RTL/Persian text
   renders garbled: wrong run order (no bidi L2) + mirrored RTL runs"*
   with a screenshot and a minimal repro.
2. Open a PR from a branch based on the latest `main`, applying
   `patch/zed-rtl.patch` (refresh it if `main` moved).
3. Reference the earlier attempt (PR #60115) and explain what was missing
   (per-run reordering alone fixes letters but not word order; L2 fixes word
   order; the two together work).

`docs/TECHNICAL.md` contains the full explanation you can paste into the
PR description. **This is what I recommend above everything else.** Until it
lands, Options A/B/C are your stopgaps.

---

## Comparison

| | Survives official update | No third-party install | Effort | Fresh features/security |
|---|---|---|---|---|
| A. patch + disable updates | yes, forever | yes, one file | one click | frozen |
| B. patch, re-run on update | yes, after re-patch | yes, one file | one click/update | yes |
| C. self-healing task | yes, automatic | yes, one file | setup once | yes |
| **D. upstream merge** | **yes, by design** | **yes, nothing** | PR | **yes** |

<div dir="rtl" align="right">

### توصیه نهایی

- **برای خودت همین الان:** گزینه‌ی A (یا B).
- **برای همه‌ی همزبان‌هایت و آینده:** گزینه‌ی D. وقتی این پچ توی خود Zed مرج بشه، مشکل برای همیشه و بدون هیچ نصبی حل می‌شه. من کل متن Issue/PR رو هم آماده می‌کنم که فقط کپی‌اش کنی.
- «جایگزین فایل خاص» مثل dll یا یه ابزار کوچیک: **تکنیکالن ممکن نیست** (همون‌طور که بالا توضیح دادم). هر کسی ادعاش کنه، داره گمراهت می‌کنه.

</div>
