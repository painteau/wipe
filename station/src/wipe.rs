use std::fs::OpenOptions;
use std::io::Write;
use std::sync::{Arc, Mutex};
use std::time::Instant;
use crate::slot::WipeProgress;

pub fn wipe_device(
    dev: &str,
    size_bytes: u64,
    progress: Arc<Mutex<WipeProgress>>,
) -> Result<(), String> {
    let mut file = OpenOptions::new()
        .write(true)
        .open(dev)
        .map_err(|e| format!("open {}: {}", dev, e))?;

    const BUF: usize = 4 * 1024 * 1024; // 4 MB
    let zeros = vec![0u8; BUF];
    let mut written = 0u64;
    let start = Instant::now();

    loop {
        let remaining = size_bytes.saturating_sub(written);
        if remaining == 0 { break; }
        let chunk = remaining.min(BUF as u64) as usize;

        match file.write_all(&zeros[..chunk]) {
            Ok(_) => {
                written += chunk as u64;
                let secs = start.elapsed().as_secs_f64();
                let mut p = progress.lock().unwrap();
                p.bytes_written = written;
                p.speed_bps = if secs > 0.1 { written as f64 / secs } else { 0.0 };
                p.elapsed_secs = secs as u64;
            }
            Err(e) if e.raw_os_error() == Some(28) => break, // ENOSPC = disk full = wipe complete
            Err(e) => return Err(e.to_string()),
        }
    }

    file.flush().map_err(|e| e.to_string())?;
    Ok(())
}
