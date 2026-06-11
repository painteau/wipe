use std::fs;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

#[cfg(all(target_os = "linux", feature = "gpio"))]
use rppal::gpio::Gpio;

#[derive(Clone, Debug)]
pub struct DiskInfo {
    pub model: String,
    pub serial: String,
    pub size_str: String,
    pub size_bytes: u64,
    pub eta_str: String,
}

#[derive(Clone, Debug, Default)]
pub struct WipeProgress {
    pub bytes_written: u64,
    pub total_bytes: u64,
    pub speed_bps: f64,
    pub elapsed_secs: u64,
}

impl WipeProgress {
    pub fn blocks_done(&self) -> usize {
        if self.total_bytes == 0 { return 0; }
        ((self.bytes_written as f64 / self.total_bytes as f64) * 100.0) as usize
    }

    pub fn percent(&self) -> f64 {
        if self.total_bytes == 0 { return 0.0; }
        (self.bytes_written as f64 / self.total_bytes as f64) * 100.0
    }

    pub fn eta_secs(&self) -> u64 {
        if self.speed_bps <= 0.0 { return 0; }
        let remaining = self.total_bytes.saturating_sub(self.bytes_written);
        (remaining as f64 / self.speed_bps) as u64
    }
}

#[derive(Clone, Debug)]
pub enum SlotState {
    WaitingForDisk,
    SsdRejected { model: String },
    Ready(DiskInfo),
    Wiping { info: DiskInfo, progress: WipeProgress },
    Done { info: DiskInfo, elapsed_secs: u64 },
    Error { message: String },
}

pub struct SlotConfig {
    pub id: usize,
    pub dev: String,
    pub gpio_pin: u8,
}

pub struct SlotHandle {
    pub state: Arc<Mutex<SlotState>>,
    _thread: thread::JoinHandle<()>,
}

impl SlotHandle {
    pub fn spawn(config: SlotConfig) -> Self {
        let state = Arc::new(Mutex::new(SlotState::WaitingForDisk));
        let state_ref = Arc::clone(&state);
        let thread = thread::spawn(move || run_slot(config, state_ref));
        SlotHandle { state, _thread: thread }
    }
}

fn set(state: &Arc<Mutex<SlotState>>, new: SlotState) {
    *state.lock().unwrap() = new;
}

fn show_error(state: &Arc<Mutex<SlotState>>, msg: impl Into<String>) {
    set(state, SlotState::Error { message: msg.into() });
    thread::sleep(Duration::from_secs(8));
}

fn run_slot(config: SlotConfig, state: Arc<Mutex<SlotState>>) {
    loop {
        set(&state, SlotState::WaitingForDisk);
        wait_for_disk(&config.dev);

        let info = match read_disk_info(&config.dev) {
            Ok(i) => i,
            Err(e) => { show_error(&state, e); wait_disk_removed(&config.dev); continue; }
        };

        if !is_rotational(&config.dev) {
            set(&state, SlotState::SsdRejected { model: info.model.clone() });
            wait_disk_removed(&config.dev);
            continue;
        }

        set(&state, SlotState::Ready(info.clone()));
        if !wait_button(config.gpio_pin, &config.dev) { continue; }
        if !is_block_device(&config.dev) { continue; }

        let progress = Arc::new(Mutex::new(WipeProgress {
            total_bytes: info.size_bytes,
            ..Default::default()
        }));

        let (tx, rx) = std::sync::mpsc::channel::<Result<(), String>>();
        let pw = Arc::clone(&progress);
        let dev = config.dev.clone();
        let size = info.size_bytes;
        thread::spawn(move || { let _ = tx.send(crate::wipe::wipe_device(&dev, size, pw)); });

        let start = Instant::now();
        let mut disconnected = false;

        loop {
            // Détection proactive déconnexion (avant même que write échoue)
            if !is_block_device(&config.dev) {
                disconnected = true;
                // Laisser le thread wipe mourir proprement (max 3s)
                let _ = rx.recv_timeout(Duration::from_secs(3));
                break;
            }

            let p = progress.lock().unwrap().clone();
            set(&state, SlotState::Wiping { info: info.clone(), progress: p });

            match rx.try_recv() {
                Ok(Ok(_)) => {
                    set(&state, SlotState::Done {
                        info: info.clone(),
                        elapsed_secs: start.elapsed().as_secs(),
                    });
                    break;
                }
                Ok(Err(e)) => {
                    // Erreur IO (peut aussi être une deconnexion detectee par write)
                    let msg = if e.contains("Input/output") || e.contains("EIO") || e.contains("No such") {
                        "DISQUE DECONNECTE pendant l'effacement !".into()
                    } else {
                        e
                    };
                    show_error(&state, msg);
                    break;
                }
                Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                    show_error(&state, "wipe thread crashed");
                    break;
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => {
                    thread::sleep(Duration::from_millis(200));
                }
            }
        }

        if disconnected {
            show_error(&state, "DISQUE DECONNECTE pendant l'effacement !");
        }

        wait_disk_removed(&config.dev);
    }
}

fn wait_for_disk(dev: &str) {
    loop {
        if is_block_device(dev) {
            thread::sleep(Duration::from_millis(500));
            return;
        }
        thread::sleep(Duration::from_secs(1));
    }
}

fn wait_disk_removed(dev: &str) {
    while is_block_device(dev) { thread::sleep(Duration::from_secs(1)); }
    thread::sleep(Duration::from_millis(500));
}

fn is_block_device(dev: &str) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::FileTypeExt;
        return fs::metadata(dev).map(|m| m.file_type().is_block_device()).unwrap_or(false);
    }
    #[cfg(not(unix))]
    { let _ = dev; false }
}

fn is_rotational(dev: &str) -> bool {
    let name = Path::new(dev).file_name().and_then(|n| n.to_str()).unwrap_or("");
    fs::read_to_string(format!("/sys/block/{}/queue/rotational", name))
        .unwrap_or_default().trim() == "1"
}

fn read_disk_info(dev: &str) -> Result<DiskInfo, String> {
    let name = Path::new(dev).file_name()
        .and_then(|n| n.to_str())
        .ok_or("invalid device")?;

    let size_sectors: u64 = fs::read_to_string(format!("/sys/block/{}/size", name))
        .unwrap_or_default().trim().parse().unwrap_or(0);
    if size_sectors == 0 { return Err("cannot read disk size".into()); }
    let size_bytes = size_sectors * 512;

    let model = fs::read_to_string(format!("/sys/block/{}/device/model", name))
        .unwrap_or_default().trim().to_string();

    let serial = std::process::Command::new("udevadm")
        .args(["info", "--query=all", &format!("--name={}", dev)])
        .output().ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.lines().find(|l| l.contains("ID_SERIAL="))
            .map(|l| l.split('=').last().unwrap_or("").to_string()))
        .unwrap_or_else(|| "unknown".into());

    Ok(DiskInfo {
        model,
        serial,
        size_str: fmt_bytes(size_bytes),
        size_bytes,
        eta_str: fmt_duration(size_bytes / 104_857_600),
    })
}

fn wait_button(gpio_pin: u8, dev: &str) -> bool {
    #[cfg(all(target_os = "linux", feature = "gpio"))]
    if let Ok(gpio) = Gpio::new() {
        if let Ok(pin) = gpio.get(gpio_pin) {
            let pin = pin.into_input_pullup();
            loop {
                if !is_block_device(dev) { return false; }
                if pin.is_low() {
                    thread::sleep(Duration::from_millis(50));
                    if pin.is_low() { return true; }
                }
                thread::sleep(Duration::from_millis(50));
            }
        }
    }
    loop {
        if !is_block_device(dev) { return false; }
        thread::sleep(Duration::from_millis(200));
    }
}

pub fn fmt_bytes(bytes: u64) -> String {
    const GB: u64 = 1_000_000_000;
    const TB: u64 = 1_000 * GB;
    if bytes >= TB { format!("{:.1} TB", bytes as f64 / TB as f64) }
    else { format!("{:.0} GB", bytes as f64 / GB as f64) }
}

pub fn fmt_duration(secs: u64) -> String {
    let h = secs / 3600;
    let m = (secs % 3600) / 60;
    let s = secs % 60;
    if h > 0 { format!("{}h{:02}m", h, m) }
    else if m > 0 { format!("{}m{:02}s", m, s) }
    else { format!("{}s", s) }
}
