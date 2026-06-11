use std::io::Write;
use std::time::Duration;
use sha2::{Sha256, Digest};

const CURRENT_VERSION: &str = env!("CARGO_PKG_VERSION");
const VERSION_URL: &str =
    "https://raw.githubusercontent.com/painteau/wipe/main/station/VERSION";
const BINARY_URL: &str =
    "https://github.com/painteau/wipe/releases/latest/download/wipe-station";
const SHA256_URL: &str =
    "https://github.com/painteau/wipe/releases/latest/download/wipe-station.sha256";
const TIMEOUT: u64 = 7;

pub fn check_and_update() {
    splash();

    let client = match reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(TIMEOUT))
        .build()
    {
        Ok(c) => c,
        Err(_) => { no_network(); return; }
    };

    let remote = match client.get(VERSION_URL).send().and_then(|r| r.text()) {
        Ok(v) => v.trim().to_string(),
        Err(_) => { no_network(); return; }
    };

    if !is_newer(&remote, CURRENT_VERSION) {
        println!("  \x1b[32m[OK] v{} -- up to date.\x1b[0m", CURRENT_VERSION);
        std::thread::sleep(Duration::from_secs(1));
        return;
    }

    println!("  \x1b[33m[~] v{} available -- downloading...\x1b[0m", remote);

    let tmp = "/tmp/wipe-station-update";

    let mut resp = match client.get(BINARY_URL).send() {
        Ok(r) => r,
        Err(e) => { eprintln!("  Error: {}", e); sleep_short(); return; }
    };
    let mut out = match std::fs::File::create(tmp) {
        Ok(f) => f,
        Err(e) => { eprintln!("  Error: {}", e); sleep_short(); return; }
    };
    if let Err(e) = std::io::copy(&mut resp, &mut out) {
        eprintln!("  Download error: {}", e); sleep_short(); return;
    }
    drop(out);

    let expected = match client.get(SHA256_URL).send().and_then(|r| r.text()) {
        Ok(t) => t.split_whitespace().next().unwrap_or("").to_string(),
        Err(_) => {
            println!("  \x1b[31m[!] SHA256 unavailable -- update blocked.\x1b[0m");
            std::fs::remove_file(tmp).ok();
            sleep_short();
            return;
        }
    };
    let data = std::fs::read(tmp).unwrap_or_default();
    let actual = hex::encode(Sha256::digest(&data));
    if actual != expected {
        println!("  \x1b[31m[!] SHA256 mismatch -- update rejected.\x1b[0m");
        std::fs::remove_file(tmp).ok();
        sleep_short();
        return;
    }

    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => { eprintln!("  current_exe: {}", e); sleep_short(); return; }
    };
    if let Err(e) = std::fs::copy(tmp, &exe) {
        eprintln!("  Replace error: {}", e); sleep_short(); return;
    }
    std::fs::remove_file(tmp).ok();

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).ok();
    }

    println!("  \x1b[33m[~] v{} -> v{} -- restarting...\x1b[0m", CURRENT_VERSION, remote);
    std::thread::sleep(Duration::from_secs(1));

    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let err = std::process::Command::new(&exe).exec();
        eprintln!("exec: {}", err);
    }
    std::process::exit(0);
}

fn splash() {
    print!("\x1b[2J\x1b[H");
    println!("\x1b[36m");
    println!("  \u{2588}\u{2588}\u{2557}    \u{2588}\u{2588}\u{2557}\u{2588}\u{2588}\u{2557}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557} \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557}");
    println!("  \u{2588}\u{2588}\u{2551}    \u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2588}\u{2588}\u{2557}\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2550}\u{2550}\u{255d}");
    println!("  \u{2588}\u{2588}\u{2551} \u{2588}\u{2557} \u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2554}\u{255d}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557}");
    println!("  \u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2588}\u{2557}\u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2550}\u{255d} \u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{255d}");
    println!("  \u{255a}\u{2588}\u{2588}\u{2588}\u{2554}\u{2588}\u{2588}\u{2588}\u{2554}\u{255d}\u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2551}     \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557}");
    println!("   \u{255a}\u{2550}\u{2550}\u{255d}\u{255a}\u{2550}\u{2550}\u{255d} \u{255a}\u{2550}\u{255d}\u{255a}\u{2550}\u{255d}     \u{255a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{255d}");
    println!("\x1b[0m");
    println!("  \x1b[2mWipe Station  v{}\x1b[0m", CURRENT_VERSION);
    println!("  \x1b[2m{}\x1b[0m", chrono::Local::now().format("%Y-%m-%d %H:%M:%S"));
    println!();

    for i in (1..=TIMEOUT).rev() {
        print!("\r  \x1b[2mChecking for updates... {}s\x1b[0m  ", i);
        std::io::stdout().flush().ok();
        std::thread::sleep(Duration::from_secs(1));
    }
    println!();
}

fn no_network() {
    println!("  \x1b[2mNo network -- running local v{}.\x1b[0m", CURRENT_VERSION);
    std::thread::sleep(Duration::from_secs(1));
}

fn sleep_short() {
    std::thread::sleep(Duration::from_secs(2));
}

fn is_newer(remote: &str, current: &str) -> bool {
    let parse = |v: &str| -> Vec<u32> {
        v.trim().split('.').filter_map(|n| n.parse().ok()).collect()
    };
    parse(remote) > parse(current)
}
