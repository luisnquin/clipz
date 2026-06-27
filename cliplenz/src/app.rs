//! iced application: a fuzzy dmenu with an optional image/text preview pane.
//! Knows nothing about any clipboard backend — it reads lines, lets you pick
//! one, and prints it. Rich preview is delegated to a user `--preview` command.

use std::cell::Cell;
use std::collections::HashMap;

use iced::widget::image::Handle;
use iced::widget::scrollable::AbsoluteOffset;
use iced::widget::{
    column, container, mouse_area, responsive, row, scrollable, text, text_input, Space,
};
use iced::{event, keyboard, ContentFit, Element, Event, Length, Size, Subscription, Task};
use iced_layershell::to_layer_message;

use crate::cli::Args;
use crate::model::Entry;
use crate::theme;
use crate::{external, fuzzy::Fuzzy};

/// iced's scrollable does not virtualize; cap painted rows so large lists stay
/// snappy on the software renderer. Matches still rank over the whole input.
const MAX_VISIBLE: usize = 200;

/// Vertical extent of one list row, in pixels: text size 13 × default line
/// height 1.3 (≈16.9) + container padding 4+4 + column spacing 2. iced reports
/// viewport geometry only after a manual wheel/drag scroll, never on keyboard
/// nav, so edge detection derives row height from styling instead of measuring.
const ROW_STRIDE: f32 = 26.9;

pub fn search_id() -> iced::widget::Id {
    iced::widget::Id::new("cliplenz-search")
}

fn list_id() -> iced::widget::Id {
    iced::widget::Id::new("cliplenz-list")
}

pub fn namespace() -> String {
    String::from("cliplenz")
}

pub struct State {
    entries: Vec<Entry>,
    query: String,
    /// Indices into `entries`, ordered by current match ranking.
    filtered: Vec<usize>,
    /// Cursor within `filtered`.
    selected: usize,
    fuzzy: Fuzzy,
    preview_cmd: Option<String>,
    prompt: String,
    placeholder: String,
    /// Keyed by entry index; only populated when a preview command is set.
    preview_cache: HashMap<usize, Preview>,
    /// Our belief of the list's current absolute scroll offset (y, px). Kept in
    /// sync via `Message::Scrolled` so wheel scrolls don't desync edge math.
    scroll_y: f32,
    /// List viewport height (px), captured during `view` via `responsive`.
    viewport_h: Cell<f32>,
}

#[derive(Clone)]
enum Preview {
    Image { handle: Handle, caption: String },
    Text(String),
    Error(String),
}

#[to_layer_message]
#[derive(Debug, Clone)]
pub enum Message {
    Query(String),
    Move(i32),
    Scrolled(f32),
    Select(usize),
    Accept,
    Quit,
}

impl State {
    pub fn boot(entries: Vec<Entry>, args: Args) -> (Self, Task<Message>) {
        let mut state = State {
            filtered: (0..entries.len()).collect(),
            entries,
            query: String::new(),
            selected: 0,
            fuzzy: Fuzzy::new(),
            preview_cmd: args.preview,
            prompt: args.prompt,
            placeholder: args.placeholder,
            preview_cache: HashMap::new(),
            scroll_y: 0.0,
            viewport_h: Cell::new(0.0),
        };
        state.ensure_preview();
        (state, iced::widget::operation::focus(search_id()))
    }

    fn focused_index(&self) -> Option<usize> {
        self.filtered.get(self.selected).copied()
    }

    /// Run + cache the preview command for the focused entry, on demand.
    fn ensure_preview(&mut self) {
        let Some(cmd) = self.preview_cmd.clone() else {
            return;
        };
        let Some(idx) = self.focused_index() else {
            return;
        };
        if self.preview_cache.contains_key(&idx) {
            return;
        }
        let preview = load_preview(&cmd, &self.entries[idx].raw);
        self.preview_cache.insert(idx, preview);
    }

    fn recompute(&mut self) {
        self.filtered = self.fuzzy.filter(&self.entries, &self.query);
        self.selected = 0;
        self.ensure_preview();
    }

    /// Scroll the list only when the focused row would fall outside the current
    /// page: nudge up to the row's top when above the viewport, or down so its
    /// bottom is flush when below. The row otherwise stays put, like a pager.
    fn keep_selected_visible(&mut self) -> Task<Message> {
        let viewport_h = self.viewport_h.get();
        let visible = self.filtered.len().min(MAX_VISIBLE);
        if viewport_h <= 0.0 || visible == 0 {
            return Task::none();
        }

        let sel_top = self.selected as f32 * ROW_STRIDE;
        let sel_bottom = sel_top + ROW_STRIDE;
        let mut y = self.scroll_y;
        if sel_top < y {
            y = sel_top;
        } else if sel_bottom > y + viewport_h {
            y = sel_bottom - viewport_h;
        }

        let max_y = (visible as f32 * ROW_STRIDE - viewport_h).max(0.0);
        y = y.clamp(0.0, max_y);
        if (y - self.scroll_y).abs() < 0.5 {
            return Task::none();
        }

        self.scroll_y = y;
        iced::widget::operation::scroll_to(list_id(), AbsoluteOffset { x: 0.0, y })
    }

    pub fn update(&mut self, message: Message) -> Task<Message> {
        match message {
            Message::Query(q) => {
                self.query = q;
                self.recompute();
                return self.keep_selected_visible();
            }
            Message::Move(delta) => {
                let visible = self.filtered.len().min(MAX_VISIBLE);
                if visible > 0 {
                    let cur = self.selected as i32;
                    self.selected = (cur + delta).rem_euclid(visible as i32) as usize;
                    self.ensure_preview();
                    return self.keep_selected_visible();
                }
            }
            Message::Scrolled(y) => {
                self.scroll_y = y;
            }
            Message::Select(pos) if pos < self.filtered.len() => {
                self.selected = pos;
                self.ensure_preview();
            }
            Message::Select(_) => {}
            Message::Accept => {
                if let Some(idx) = self.focused_index() {
                    // dmenu contract: selected raw line -> stdout, exit 0.
                    println!("{}", self.entries[idx].raw);
                    std::process::exit(0);
                }
                std::process::exit(1);
            }
            // Cancel: no output, non-zero exit (callers guard on empty output).
            Message::Quit => std::process::exit(1),
            // Layershell control variants injected by `#[to_layer_message]`; unused.
            _ => {}
        }
        Task::none()
    }

    pub fn view(&self) -> Element<'_, Message> {
        let prompt = text(self.prompt.clone()).size(15).color(theme::MATCH);
        let input = text_input(&self.placeholder, &self.query)
            .id(search_id())
            .on_input(Message::Query)
            .on_submit(Message::Accept)
            .size(14)
            .style(theme::search_input)
            .width(Length::Fill);
        let header = row![prompt, input]
            .spacing(8)
            .align_y(iced::Alignment::Center);

        let body: Element<Message> = if self.preview_cmd.is_some() {
            row![
                container(self.view_list())
                    .width(Length::FillPortion(5))
                    .height(Length::Fill),
                container(self.view_preview())
                    .width(Length::FillPortion(6))
                    .height(Length::Fill)
                    .padding(8),
            ]
            .spacing(8)
            .height(Length::Fill)
            .into()
        } else {
            container(self.view_list()).height(Length::Fill).into()
        };

        let inner = column![header, body]
            .spacing(10)
            .padding(14)
            .width(Length::Fill)
            .height(Length::Fill);

        container(inner)
            .style(theme::root_panel)
            .width(Length::Fill)
            .height(Length::Fill)
            .into()
    }

    fn view_list(&self) -> Element<'_, Message> {
        if self.filtered.is_empty() {
            let label = if self.entries.is_empty() {
                "No entries on stdin"
            } else {
                "No matches"
            };
            return container(text(label).color(theme::DIM).size(13))
                .padding(8)
                .into();
        }

        // `responsive` hands us the list's allotted size during layout; stash
        // its height so `keep_selected_visible` knows the page extent.
        responsive(move |size: Size| {
            self.viewport_h.set(size.height);
            self.list_scrollable()
        })
        .into()
    }

    fn list_scrollable(&self) -> Element<'_, Message> {
        let mut rows = column![].spacing(2);
        for (pos, &idx) in self.filtered.iter().take(MAX_VISIBLE).enumerate() {
            rows = rows.push(self.view_row(pos, &self.entries[idx]));
        }
        if self.filtered.len() > MAX_VISIBLE {
            let more = self.filtered.len() - MAX_VISIBLE;
            rows = rows.push(
                text(format!("+{more} more — narrow the search"))
                    .size(11)
                    .color(theme::DIM),
            );
        }

        scrollable(rows)
            .id(list_id())
            .on_scroll(|vp| Message::Scrolled(vp.absolute_offset().y))
            .style(theme::scroll)
            .height(Length::Fill)
            .into()
    }

    fn view_row<'a>(&'a self, pos: usize, entry: &'a Entry) -> Element<'a, Message> {
        let selected = pos == self.selected;
        let label = first_line(&entry.display());
        let content = if selected {
            text(label).size(13).color(theme::SELECTION_TEXT)
        } else {
            text(label).size(13).color(theme::TEXT)
        };

        let styled = container(content)
            .padding([4, 8])
            .width(Length::Fill)
            .style(if selected {
                theme::selected_row
            } else {
                theme::transparent_row
            });

        mouse_area(styled).on_press(Message::Select(pos)).into()
    }

    fn view_preview(&self) -> Element<'_, Message> {
        let Some(idx) = self.focused_index() else {
            return blank();
        };
        match self.preview_cache.get(&idx) {
            Some(Preview::Image { handle, caption }) => {
                let canvas = iced::widget::image(handle.clone())
                    .content_fit(ContentFit::Contain)
                    .width(Length::Fill)
                    .height(Length::Fill);
                column![canvas, text(caption.clone()).size(11).color(theme::DIM)]
                    .spacing(6)
                    .into()
            }
            Some(Preview::Text(body)) => scrollable(text(body.clone()).size(13).color(theme::TEXT))
                .style(theme::scroll)
                .width(Length::Fill)
                .height(Length::Fill)
                .into(),
            Some(Preview::Error(e)) => container(text(format!("⚠ {e}")).size(12).color(theme::MATCH))
                .center_x(Length::Fill)
                .center_y(Length::Fill)
                .into(),
            None => blank(),
        }
    }

    pub fn subscription(&self) -> Subscription<Message> {
        event::listen_with(|event, _status, _window| {
            use keyboard::key::Named;
            use keyboard::Key;
            let Event::Keyboard(keyboard::Event::KeyPressed { key, modifiers, .. }) = event else {
                return None;
            };
            match key.as_ref() {
                Key::Named(Named::Escape) => Some(Message::Quit),
                Key::Named(Named::Enter) => Some(Message::Accept),
                Key::Named(Named::ArrowDown) => Some(Message::Move(1)),
                Key::Named(Named::ArrowUp) => Some(Message::Move(-1)),
                Key::Character("n") if modifiers.control() => Some(Message::Move(1)),
                Key::Character("p") if modifiers.control() => Some(Message::Move(-1)),
                Key::Character("j") if modifiers.control() => Some(Message::Move(1)),
                Key::Character("k") if modifiers.control() => Some(Message::Move(-1)),
                Key::Character("c") if modifiers.control() => Some(Message::Quit),
                _ => None,
            }
        })
    }
}

fn blank() -> Element<'static, Message> {
    Space::new().width(Length::Fill).height(Length::Fill).into()
}

fn load_preview(cmd: &str, line: &str) -> Preview {
    let bytes = match external::run_preview(cmd, line) {
        Ok(b) => b,
        Err(e) => return Preview::Error(e),
    };
    if image::guess_format(&bytes).is_ok() {
        match image::load_from_memory(&bytes) {
            Ok(img) => {
                let rgba = img.to_rgba8();
                let (w, h) = rgba.dimensions();
                return Preview::Image {
                    handle: Handle::from_rgba(w, h, rgba.into_raw()),
                    caption: format!("{w}×{h}"),
                };
            }
            Err(e) => return Preview::Error(format!("decode image: {e}")),
        }
    }
    Preview::Text(String::from_utf8_lossy(&bytes).into_owned())
}

fn first_line(s: &str) -> String {
    let line = s.lines().next().unwrap_or("");
    let trimmed: String = line.chars().take(200).collect();
    if line.chars().count() > 200 {
        format!("{trimmed}…")
    } else {
        trimmed
    }
}
