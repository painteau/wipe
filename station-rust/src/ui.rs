use ratatui::{
    Frame,
    layout::{Constraint, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph},
};
use crate::slot::{SlotState, WipeProgress, DiskInfo, fmt_bytes, fmt_duration};

const VERSION: &str = "2.0.0";
const COLS: usize = 10;
const ROWS: usize = 10;

pub fn render(frame: &mut Frame, states: &[SlotState]) {
    let area = frame.area();
    let layout = Layout::vertical([Constraint::Length(3), Constraint::Min(0)]).split(area);
    render_header(frame, layout[0]);

    let panels = Layout::horizontal([
        Constraint::Percentage(50),
        Constraint::Percentage(50),
    ]).split(layout[1]);

    for (i, state) in states.iter().enumerate() {
        if i < panels.len() {
            render_slot(frame, panels[i], i + 1, state);
        }
    }
}

fn render_header(frame: &mut Frame, area: Rect) {
    let now = chrono::Local::now().format("%Y-%m-%d %H:%M:%S");
    let line = Line::from(vec![
        Span::styled(
            format!("  WIPE STATION v{}  |  {}  |  [q] quitter", VERSION, now),
            Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD),
        ),
    ]);
    frame.render_widget(
        Paragraph::new(line).block(Block::default().borders(Borders::ALL)
            .border_style(Style::default().fg(Color::Cyan))),
        area,
    );
}

fn render_slot(frame: &mut Frame, area: Rect, id: usize, state: &SlotState) {
    let label = format!(" SLOT {} ", id);
    let (color, lines): (Color, Vec<Line<'static>>) = match state {
        SlotState::WaitingForDisk => (Color::DarkGray, lines_waiting()),
        SlotState::SsdRejected { model } => (Color::Red, lines_ssd(model)),
        SlotState::Ready(info) => (Color::Yellow, lines_ready(info)),
        SlotState::Wiping { info, progress } => (Color::Cyan, lines_wiping(info, progress)),
        SlotState::Done { info, elapsed_secs } => (Color::Green, lines_done(info, *elapsed_secs)),
        SlotState::Error { message } => (Color::Red, lines_error(message)),
    };
    let block = Block::default()
        .title(Span::styled(label, Style::default().fg(color).add_modifier(Modifier::BOLD)))
        .borders(Borders::ALL)
        .border_style(Style::default().fg(color));
    frame.render_widget(Paragraph::new(lines).block(block), area);
}

fn lines_waiting() -> Vec<Line<'static>> {
    vec![
        Line::from(""),
        Line::from(""),
        Line::from(""),
        Line::from(""),
        Line::from(Span::styled(
            "  En attente d'un disque HDD...",
            Style::default().fg(Color::DarkGray),
        )),
    ]
}

fn lines_ssd(model: &str) -> Vec<Line<'static>> {
    vec![
        Line::from(""),
        Line::from(Span::styled(
            format!("  [!] SSD detecte : {}", model),
            Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
        )),
        Line::from(Span::styled(
            "  HDD uniquement. Retirer le disque.",
            Style::default().fg(Color::DarkGray),
        )),
    ]
}

fn lines_ready(info: &DiskInfo) -> Vec<Line<'static>> {
    let mut lines = disk_header(info, Color::Yellow);
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        "  > Appuyer sur le bouton pour demarrer <",
        Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD | Modifier::SLOW_BLINK),
    )));
    lines
}

fn lines_wiping(info: &DiskInfo, progress: &WipeProgress) -> Vec<Line<'static>> {
    let blocks = progress.blocks_done().min(COLS * ROWS);
    let pct = progress.percent();
    let speed_mb = progress.speed_bps / 1_048_576.0;
    let elapsed = fmt_duration(progress.elapsed_secs);
    let eta = fmt_duration(progress.eta_secs());

    let mut lines = disk_header(info, Color::Cyan);
    lines.push(Line::from(""));
    lines.extend(defrag_grid(blocks, COLS * ROWS, Color::Green, Color::Cyan));
    lines.push(Line::from(""));
    lines.push(Line::from(vec![
        Span::styled(
            format!("  {:.1}%", pct),
            Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("  {:.0} MB/s  |  +{}  |  -{}", speed_mb, elapsed, eta),
            Style::default().fg(Color::DarkGray),
        ),
    ]));
    lines
}

fn lines_done(info: &DiskInfo, elapsed_secs: u64) -> Vec<Line<'static>> {
    let total = COLS * ROWS;
    let mut lines = disk_header(info, Color::Green);
    lines.push(Line::from(""));
    lines.extend(defrag_grid(total, total, Color::Green, Color::Green));
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        format!("  [OK] TERMINE  {}  en {}", info.size_str, fmt_duration(elapsed_secs)),
        Style::default().fg(Color::Green).add_modifier(Modifier::BOLD),
    )));
    lines.push(Line::from(Span::styled(
        "  Retirer le disque.",
        Style::default().fg(Color::DarkGray),
    )));
    lines
}

fn lines_error(message: &str) -> Vec<Line<'static>> {
    vec![
        Line::from(""),
        Line::from(Span::styled(
            "  [!!] ERREUR",
            Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
        )),
        Line::from(Span::styled(
            format!("  {}", message),
            Style::default().fg(Color::DarkGray),
        )),
        Line::from(""),
        Line::from(Span::styled(
            "  Retirer le disque pour reessayer.",
            Style::default().fg(Color::DarkGray),
        )),
    ]
}

fn disk_header(info: &DiskInfo, accent: Color) -> Vec<Line<'static>> {
    vec![
        Line::from(vec![
            Span::styled("  Modele : ", Style::default().fg(Color::DarkGray)),
            Span::styled(info.model.clone(), Style::default().fg(Color::White).add_modifier(Modifier::BOLD)),
        ]),
        Line::from(vec![
            Span::styled("  Serie  : ", Style::default().fg(Color::DarkGray)),
            Span::styled(info.serial.clone(), Style::default().fg(Color::White)),
        ]),
        Line::from(vec![
            Span::styled("  Taille : ", Style::default().fg(Color::DarkGray)),
            Span::styled(info.size_str.clone(), Style::default().fg(accent).add_modifier(Modifier::BOLD)),
        ]),
        Line::from(vec![
            Span::styled("  Estime : ", Style::default().fg(Color::DarkGray)),
            Span::styled(format!("~{}", info.eta_str), Style::default().fg(Color::DarkGray)),
        ]),
    ]
}

fn defrag_grid(done: usize, total: usize, done_color: Color, frontier_color: Color) -> Vec<Line<'static>> {
    (0..ROWS).map(|row| {
        let mut spans = vec![Span::raw("  ")];
        for col in 0..COLS {
            let idx = row * COLS + col;
            let (ch, color) = if idx < done {
                ("##", done_color)
            } else if idx == done && done < total {
                ("##", frontier_color)
            } else {
                ("..", Color::DarkGray)
            };
            spans.push(Span::styled(ch, Style::default().fg(color)));
            spans.push(Span::raw(" "));
        };
        Line::from(spans)
    }).collect()
}
