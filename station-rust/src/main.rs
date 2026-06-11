mod slot;
mod ui;
mod update;
mod wipe;

use std::thread;
use std::time::{Duration, Instant};
use crossterm::{
    event::{self, Event, KeyCode, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{Terminal, backend::CrosstermBackend};
use slot::SlotHandle;

fn main() -> anyhow::Result<()> {
    update::check_and_update();

    // Désactiver blanking écran TTY
    #[cfg(target_os = "linux")]
    {
        use std::io::Write;
        if let Ok(mut tty) = std::fs::OpenOptions::new().write(true).open("/dev/tty1") {
            let _ = tty.write_all(b"\x1b[9;0]");
        }
    }

    spawn_reboot_watchdog(17, 27);

    enable_raw_mode()?;
    execute!(std::io::stdout(), EnterAlternateScreen)?;

    let backend = CrosstermBackend::new(std::io::stdout());
    let mut terminal = Terminal::new(backend)?;

    let handles = vec![
        SlotHandle::spawn(slot::SlotConfig { id: 1, dev: "/dev/sda".into(), gpio_pin: 17 }),
        SlotHandle::spawn(slot::SlotConfig { id: 2, dev: "/dev/sdb".into(), gpio_pin: 27 }),
    ];

    let result = run_ui(&mut terminal, &handles);

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    result
}

fn spawn_reboot_watchdog(pin_a: u8, pin_b: u8) {
    thread::spawn(move || {
        let mut hold_start: Option<Instant> = None;
        loop {
            if slot::read_pin_low(pin_a) && slot::read_pin_low(pin_b) {
                let since = hold_start.get_or_insert_with(Instant::now);
                if since.elapsed() >= Duration::from_secs(10) {
                    let _ = std::process::Command::new("sudo")
                        .args(["reboot"])
                        .spawn();
                    // Attendre le reboot système
                    thread::sleep(Duration::from_secs(60));
                }
            } else {
                hold_start = None;
            }
            thread::sleep(Duration::from_millis(100));
        }
    });
}

fn run_ui(
    terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>,
    handles: &[SlotHandle],
) -> anyhow::Result<()> {
    loop {
        terminal.draw(|f| {
            let states: Vec<_> = handles.iter()
                .map(|h| h.state.lock().unwrap().clone())
                .collect();
            ui::render(f, &states);
        })?;

        if event::poll(Duration::from_millis(100))? {
            if let Event::Key(key) = event::read()? {
                if let (KeyCode::Char('c'), KeyModifiers::CONTROL) = (key.code, key.modifiers) {
                    break;
                }
            }
        }
    }
    Ok(())
}
