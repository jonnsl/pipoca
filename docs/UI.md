# Aperture — Screens & UI Plan

The plan follows the [GNOME HIG](https://developer.gnome.org/hig/) and uses
libadwaita widgets as they're meant to be used. Each screen is a Vala class
backed by a Blueprint template.

## Navigation model

```
Adw.ApplicationWindow
└─ Adw.ToastOverlay
   └─ Adw.NavigationView                     ← drill-down stack (back swipe, Alt+←)
      ├─ MainPage            (root)          ← top-level views in a ViewStack
      │  ├─ Watchlist        [M1]
      │  ├─ Upcoming         [M2]
      │  ├─ Discover         [M3]
      │  └─ Watched          [M1]
      ├─ DetailsPage         (movie | show)  ← pushed from any poster/row
      │  └─ SeasonPage       (show only)     ← pushed from a season row
      └─ HistoryPage         [M4]
Dialogs (Adw.Dialog — bottom sheet on narrow windows):
   SearchDialog  ·  PreferencesDialog  ·  AboutDialog  ·  ShortcutsDialog
```

Why this shape:

- **ViewSwitcher in the header bar, ViewSwitcherBar at the bottom** below
  ~550 sp. The HIG recommends this pattern for 2–5 equal top-level views, and
  it adapts to phones without extra work. (Adw 1.9's `ViewSwitcherSidebar`
  would be an alternative if we ever pass ~5 views, e.g. custom lists.)
- **NavigationView** for drilling down (Main → Details → Season), so back
  gestures, Escape/Alt+← and narrow layouts behave as users expect.
- **Search of TMDB is a dialog**, not a tab: adding a title is a short task
  that you start from anywhere (Ctrl+N). Filtering *your own* library is a
  `Gtk.SearchBar` on the library views (Ctrl+F).

## 1. Main page

```
┌──────────────────────────────────────────────────────────────────────┐
│ [+] [🔍]     [Watchlist] [Upcoming] [Discover] [Watched]   [≡]      │  Adw.HeaderBar
├──────────────────────────────────────────────────────────────────────┤
│  (SearchBar: [ Filter library…            ]  — revealed by Ctrl+F)   │
├──────────────────────────────────────────────────────────────────────┤
│  [ All | Movies | Shows ]                         Sort: Recent ▾     │  Adw.ToggleGroup + MenuButton
│                                                                      │
│  Continue Watching                                                   │
│  ┌──────┐ ┌──────┐ ┌──────┐                                          │
│  │poster│ │poster│ │poster│   ← PosterCard: poster, progress bar,    │
│  │  ▓▓░ │ │  ▓░░ │ │  ▓▓▓●│     "S2 E5" label, ● new badge           │
│  └──────┘ └──────┘ └──────┘                                          │
│  Severance  The Bear  Andor                                          │
│                                                                      │
│  Plan to Watch                                                       │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐                        │
│  │      │ │      │ │      │ │      │ │      │   Gtk.GridView         │
│  └──────┘ └──────┘ └──────┘ └──────┘ └──────┘   (wraps responsively) │
└──────────────────────────────────────────────────────────────────────┘
```

- **Header bar:** `+` opens the SearchDialog. The search toggle reveals the
  library filter. The primary menu holds Sort options, Preferences, Keyboard
  Shortcuts and About Aperture.
- **Watchlist** has sections "Continue Watching" (shows in progress or with new
  episodes) and "Plan to Watch". The sections are headers in a `Gtk.GridView`
  (`Gtk.SectionModel`), so there's only one scrollable.
- **Watched** uses the same grid, sorted by last watched by default.
- **PosterCard** (widget): a 2:3 poster with rounded corners (`.card`), a
  title, a secondary line (year · Movie/Show, or next episode), an optional
  progress bar and an optional "New" badge. Activating it pushes DetailsPage.
  The context menu (right-click/long-press) offers Mark as Watched, Remove from
  Library and Open on TMDB.
- **Empty states** (`Adw.StatusPage`):
  - Watchlist: "Your Watchlist Is Empty" with a pill button "Search Movies &
    Shows" that opens the SearchDialog.
  - Watched: "Nothing Watched Yet".
  - Library filter with no results: "No Results Found".
- **Narrow (< 550 sp):** the switcher moves to the bottom bar, the grid drops
  to 2–3 columns, and the toggle group stays visible.

## 2. Upcoming view [M2]

```
│  Today                                                               │
│  ┌────┐  Severance                          S2 E6 · "Attila"         │
│  │img │  9:00 PM · Apple TV+                         [🔔]             │  Adw.ActionRow
│  └────┘                                                              │
│  This Week                                                           │
│  …                                                                   │
│  Later                                                               │
│  ┌────┐  Dune: Part Three                    In theaters · Dec 18     │
```

- `Gtk.ListView` in an `Adw.ClampScrollable` with `.boxed-list-separate`
  styling. Sections are Today / Tomorrow / This Week / Later.
- Empty state: "No Upcoming Releases — add shows that are still airing to see
  their next episodes here".

## 3. Discover view [M3]

```
│  Trending This Week                                         [→]      │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐  ›            │  horizontal shelf
│  Popular Movies                                             [→]      │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐  ›            │
│  Now in Theaters · Upcoming · Airing Today · Popular Shows …         │
```

- **Shelf** (widget): a header with a "See All" button and a horizontal
  `Gtk.ListView` of PosterCards. Posters already in the library get a check
  emblem.
- "See All" pushes a full grid page for that list, with infinite scroll
  (TMDB pagination).
- Offline: `Adw.StatusPage` "You're Offline" with a Retry button.

## 4. Details page

```
┌──────────────────────────────────────────────────────────────────────┐
│ [←]                                                       [⋮]        │  flat HeaderBar over backdrop
│ ░░░░░░░░░░░░░░░░░ backdrop (fades into window bg) ░░░░░░░░░░░░░░░░░ │
│ ┌────────┐  Severance                                                │  .title-1
│ │        │  2022 · TV Show · Drama, Mystery · ★ 8.4                  │  .dim-label
│ │ poster │  Apple TV+ · Returning Series                             │
│ │        │                                                           │
│ │        │  [ ✓ In Watchlist ▾ ]  [ Mark Next as Watched ]           │  .pill / .suggested-action
│ └────────┘                                                           │
│                                                                      │
│  Next: S2 E6 · "Attila"  ·  airs Fri, Oct 24                         │  Adw.ActionRow
│                                                                      │
│  Overview                                                            │
│  Mark leads a team of office workers whose memories have been …      │
│                                                                      │
│  Seasons                                                             │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ Season 1        9 episodes · 2022          ▓▓▓▓▓▓▓▓▓ 9/9  ›  │   │  Adw.ActionRow, boxed-list
│  │ Season 2       10 episodes · 2025          ▓▓▓▓▓░░░░ 5/10 ›  │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  Cast [M3]   ( ◯ ) ( ◯ ) ( ◯ ) ( ◯ )  →                              │
│  More Like This [M3]   shelf                                         │
│                                                                      │
│  Information                                                         │
│  Original Title · Original Language · Status · Runtime · Budget …    │  Adw.ActionRow list
│                                                                      │
│  Your Notes [M4]  ★★★★☆   ┌─────────────────────────────┐           │
└──────────────────────────────────────────────────────────────────────┘
```

- **Primary button changes with state:**
  - not in library → **Add to Watchlist** (`.suggested-action`),
  - movie in library → **Mark as Watched**,
  - show in progress → **Mark S2 E6 as Watched**.

  The library state button (`✓ In Watchlist ▾`) is an `Adw.SplitButton` whose
  menu has Remove from Library, and later Notify Me and Add to List.
- **Overflow menu (⋮):** Refresh Metadata, Open on TMDB, Copy Link, and
  Watch Trailer [M3].
- The backdrop is a `Gtk.Picture` (`content-fit: cover`) with a CSS gradient
  mask to the window background, so it works in both light and dark styles.
  Text never sits on top of the raw image.
- **Narrow:** an `Adw.Breakpoint` stacks the poster above the info, centers the
  title, and makes the action buttons fill the width.
- **Loading:** an `Adw.Spinner` until the details arrive (only when the title
  isn't cached). **Error:** an `Adw.StatusPage` with a Retry button.

## 5. Season page

```
│ [←]                 Season 2                              [⋮]        │  Adw.WindowTitle (show name subtitle)
│  ▓▓▓▓▓░░░░░  5 of 10 watched                 [Mark Season Watched]   │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ ┌─────┐ 1. Hello, Ms. Cobel          Jan 17 · 52 min   [✓]  │   │  EpisodeRow
│  │ │still│ Mark returns to Lumon …                              │   │
│  │ └─────┘                                                      │   │
│  │ ┌─────┐ 6. Attila                    Fri, Oct 24       [ ]  │   │  unaired → dimmed, no toggle
│  └──────────────────────────────────────────────────────────────┘   │
```

- **EpisodeRow** (widget): still image, number + title, air date · runtime, a
  2-line overview that expands on activate, and a check toggle
  (`.flat .circular`).
- Context menu: Mark Watched Up to Here, and Watched On… [M4].
- Unaired episodes are dimmed and their toggle is insensitive.
- "Mark Season Watched" asks for confirmation only when it would *unmark*
  episodes (destructive); otherwise it acts right away and offers Undo in a
  toast.

## 6. Search dialog

```
┌────────────────────────────── Add Title ───────────────────────── [✕] ┐
│  [🔍 Search movies and TV shows…                                    ]  │  SearchEntry (focused)
│  [ All | Movies | Shows ]                                             │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │ ┌──┐ Dune: Part Two                  2024 · Movie       [ + ]│    │  SearchResultRow
│  │ └──┘ Paul Atreides unites with Chani …                       │    │
│  │ ┌──┐ Dune: Prophecy                  2024 · TV Show     [ ✓ ]│    │  already in library
│  └──────────────────────────────────────────────────────────────┘    │
└───────────────────────────────────────────────────────────────────────┘
```

- An `Adw.Dialog` of ~600×700 that becomes a bottom sheet on phones.
- Debounced search (`search-delay`) against TMDB `/search/multi`.
- `+` adds the title right away (toast: "Added to Watchlist", with Undo).
  Activating the row closes the dialog and pushes DetailsPage.
- States: initial ("Search TMDB" StatusPage), loading (`Adw.Spinner`), no
  results, offline/error.

## 7. Preferences dialog

`Adw.PreferencesDialog` with one page per area:

- **General**
  - Content: Metadata Language (`Adw.ComboRow`), Region (`Adw.ComboRow`).
  - Updates: Refresh Library Automatically (`Adw.SwitchRow`).
  - Notifications [M2]: New Episodes, Movie Releases, Run in Background.
- **Advanced**
  - TMDB: Use Custom API Key (`Adw.SwitchRow`) plus an `Adw.PasswordEntryRow`.
  - Storage: Image Cache size (`Adw.ActionRow` with a Clear button), Export
    Library, Import Library, Import from Ticket Booth [M5].

## 8. Global UI conventions

- **Keyboard shortcuts:**

  | Shortcut          | Action                  |
  |-------------------|-------------------------|
  | Ctrl+N            | Add title (search)      |
  | Ctrl+F            | Filter library          |
  | Ctrl+1…5          | Switch views            |
  | F5 / Ctrl+R       | Refresh                 |
  | Ctrl+,            | Preferences             |
  | Ctrl+?            | Shortcuts               |
  | Ctrl+Q            | Quit                    |
  | Alt+← / Esc       | Back                    |

- **Feedback:** use toasts for reversible actions (with Undo) and
  `Adw.AlertDialog` only for destructive, irreversible ones (Clear Cache,
  Import that replaces the library). Show a `Adw.Banner` "Offline — showing
  saved data" while there's no network.
- **Copy:** header capitalization for titles and buttons, sentence case for
  descriptions, no trailing periods on labels.
- **Accessibility:** every icon-only button gets a tooltip and an accessible
  label; posters get the title as their accessible name; progress is exposed
  as text, not color only.
- **Style:** stock libadwaita style classes (`.card`, `.boxed-list`, `.pill`,
  `.title-1`, `.dim-label`), with custom CSS limited to poster sizing and the
  backdrop fade. Follows the system accent color.
- **Window:** 360×294 minimum, defaults to 1000×700, and remembers its size.

## Implementation order

1. Window shell: NavigationView, MainPage with ViewStack/switchers, empty
   states, breakpoints.
2. Models, Database and Library service, plus PosterCard and the Watchlist and
   Watched grids, using fixture data.
3. TmdbClient, ImageCache and SearchDialog: add real titles.
4. DetailsPage (movie, then show) and SeasonPage with EpisodeRow: tracking.
5. Preferences, background refresh, offline banner.
6. M2+: Upcoming, notifications, Discover, and so on.
