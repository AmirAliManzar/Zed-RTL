//! zed-rtl patcher.
//!
//! Small wrapper around `scripts/patch-zed.ps1` that asks Windows for
//! administrator rights (UAC) before running it, so the user can just
//! double-click the exe. No dependencies, links shell32 directly.

use std::ffi::OsStr;
use std::io::Write;
use std::os::windows::ffi::OsStrExt;
use std::process::Command;

/// The patch script, baked into the exe at build time.
const PS1: &str = include_str!("../../scripts/patch-zed.ps1");

#[link(name = "shell32")]
extern "C" {
    fn IsUserAnAdmin() -> i32;
    fn ShellExecuteW(
        hwnd: *mut std::ffi::c_void,
        op: *const u16,
        file: *const u16,
        params: *const u16,
        dir: *const u16,
        show: i32,
    ) -> isize;
}

fn wide(s: &str) -> Vec<u16> {
    OsStr::new(s).encode_wide().chain(std::iter::once(0)).collect()
}

fn is_admin() -> bool {
    // IsUserAnAdmin is deprecated but still exported by shell32 and is the
    // cheapest way to ask "did the process come back elevated?".
    unsafe { IsUserAnAdmin() != 0 }
}

/// Release asset matching this exe's own architecture.
fn default_asset() -> &'static str {
    if cfg!(target_arch = "aarch64") {
        "zed-rtl-aarch64.exe"
    } else {
        "zed-rtl-x86_64.exe"
    }
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();

    // Default to downloading the build that matches this patcher's arch,
    // unless the caller overrode -Asset / -LocalExe.
    let has_asset = args
        .iter()
        .any(|a| a.eq_ignore_ascii_case("-Asset") || a.eq_ignore_ascii_case("/Asset"));
    let has_local = args
        .iter()
        .any(|a| a.eq_ignore_ascii_case("-LocalExe") || a.eq_ignore_ascii_case("/LocalExe"));
    if !has_asset && !has_local {
        args.push("-Asset".to_string());
        args.push(default_asset().to_string());
    }

    if !is_admin() {
        println!("This patcher needs administrator rights.");
        println!("Asking Windows for permission (click Yes on the UAC prompt)...");
        let exe = std::env::current_exe().unwrap_or_default();
        let exe_str = exe.to_str().unwrap_or("zed-rtl-patcher.exe");
        let params = args.join(" ");
        let rc = unsafe {
            ShellExecuteW(
                std::ptr::null_mut(),
                wide("runas").as_ptr(),
                wide(exe_str).as_ptr(),
                wide(&params).as_ptr(),
                std::ptr::null(),
                1, // SW_SHOWNORMAL
            )
        };
        if rc as usize <= 32 {
            eprintln!("Could not start elevated (ShellExecute error {rc}).");
            eprintln!("Run it as administrator manually, or use scripts/patch-zed.ps1 instead.");
            print!("Press Enter to close... ");
            std::io::stdout().flush().ok();
            let mut s = String::new();
            std::io::stdin().read_line(&mut s).ok();
            std::process::exit(1);
        }
        // The elevated copy is now running in its own window.
        return;
    }

    println!("Running as administrator.");
    let script = std::env::temp_dir().join("zed-rtl-patcher\\patch-zed.ps1");
    if let Err(e) = std::fs::create_dir_all(script.parent().unwrap()) {
        panic!("cannot create temp dir: {e}");
    }
    if let Err(e) = std::fs::write(&script, PS1) {
        panic!("cannot write patch script to {}: {e}", script.display());
    }

    println!("---");
    let status = Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
        ])
        .arg(&script)
        .args(&args)
        .status()
        .unwrap_or_else(|e| panic!("failed to launch powershell: {e}"));
    println!("---");

    if status.success() {
        println!("Finished. If something looks wrong, run again with -Revert to restore the original Zed.");
    } else {
        println!("The patch script reported an error (exit {}). See the output above.", status.code().unwrap_or(-1));
    }

    print!("Press Enter to close... ");
    std::io::stdout().flush().ok();
    let mut s = String::new();
    std::io::stdin().read_line(&mut s).ok();
}
