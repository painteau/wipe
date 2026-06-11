mod slot;
mod ui;
mod update;
mod wipe;

use std::time::Duration;
use crossterm::{
    event::{self, Event, KeyCode, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{Terminal, backend::CrosstermBackend};
use slot::SlotHandle;

fn main() -> anyhow::Result<()> {
    // Self-update avant TUI (affiche splash sur stdout normal)
    update::check_and_update();

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
                match (key.code, key.modifiers) {
                    (KeyCode::Char('q'), _) |
                    (KeyCode::Char('c'), KeyModifiers::CONTROL) => break,
                    _ => {}
                }
            }
        }
    }
    Ok(())
}
