# Aperture — Feature List

Aperture is a GNOME app to build a watchlist of movies and TV shows, track what
you've watched, and keep up with new releases. Metadata comes from
[TMDB](https://www.themoviedb.org/); the app never streams or downloads content.

Features are grouped by milestone. **M1** is the minimum we'd ship; later
milestones are ordered by how much value they add relative to their cost.

## Core concepts

- **Title**: a movie or a TV show, identified by its TMDB id and media type.
- **Library**: every title the user has added. Each title has a *status*:

  | Status        | Movie                  | TV show                                              |
  |---------------|------------------------|------------------------------------------------------|
  | Plan to Watch | added, not watched     | added, no episodes watched                           |
  | Watching      | —                      | some aired episodes watched                          |
  | Up to Date    | —                      | all aired episodes watched, show still airing        |
  | Watched       | marked watched         | all episodes watched and show ended/cancelled        |

  Status is **derived** from watch progress, never stored by hand. A show that's
  *Up to Date* goes back to *Watching* on its own when a new episode airs. That
  fixes a common Ticket Booth complaint: a finished season stayed marked
  "watched" after new episodes aired.
- **Watch event**: the user watched a movie or episode at a given time. These
  events drive progress and the *Last Watched* sort order.

## M1 — Track your library

1. **Search TMDB** for movies and shows by title, with poster, year and type in
   the results.
2. **Add/remove** titles to/from the library in one click, from search results
   or the details page. Removing a title can be undone with a toast.
3. **Watchlist view** shows titles that are *Plan to Watch*, *Watching* or have
   new episodes. Shows you're in the middle of come first.
4. **Watched view** shows titles that are done (*Watched*, *Up to Date*).
5. **Details page** for movies and shows: backdrop, poster, title, year,
   runtime/episode count, genres, TMDB rating, overview, status, original title
   and language. Shows also get creator/network info.
6. **Mark movies watched/unwatched.**
7. **Episode tracking:** browse a show's seasons, then:
   - mark single episodes watched/unwatched,
   - mark a whole season watched,
   - "mark watched up to here" (all earlier episodes too).
8. **Next episode:** each show in progress shows "S2 E5 · Title" with a
   one-click "Mark as Watched".
9. **Filter & sort the library:**
   - filter by Movies / Shows / All,
   - sort by date added, title, or release date,
   - search the library by text (Ctrl+F).
10. **Offline-first:** metadata lives in a local SQLite database and images in
    the cache dir. The library can be browsed and edited with no network.
11. **Background refresh:** stale titles are updated from TMDB at startup, at
    most once a day per title (shows still airing first).
12. **Adaptive UI:** usable from 360 px wide (phones) up to desktop.
13. **GNOME integration:** keyboard shortcuts dialog, About dialog with TMDB
    attribution, translatable strings, follows the system light/dark style
    and accent color.

## M2 — Keep up with releases

14. **Upcoming view:** a timeline of upcoming episodes for shows in the library
    and upcoming release dates for movies on the watchlist, grouped as Today /
    This Week / Later.
15. **New badges:** titles with new episodes/releases since you last opened the
    app get a badge.
16. **Notifications:** desktop notifications (GNotification) for new episodes
    and movie releases, with a per-title "Notify me" toggle.
17. **Background updates:** keep running in the background via the Background
    portal (optional; off by default) so notifications show up even when the
    window is closed.

## M3 — Discover

18. **Discover view:** horizontal shelves of TMDB lists: Trending this week,
    Popular movies, Popular shows, Now in theaters, Upcoming movies, Airing
    today.
19. **Recommendations:** "More like this" shelf on the details page, plus a
    Discover shelf based on the library.
20. **Cast & crew** row on the details page.
21. **Trailers:** button that opens the YouTube trailer in the browser.

## M4 — Data portability

22. **Export/import** the library as a documented JSON file.

## Preferences

- **Metadata language** (TMDB `language`) and **region** (release dates). The
  default comes from the system locale. *Not implemented yet: both are always
  taken from the locale, with no preference to change them.*
- **TMDB API key:** optional user-supplied key that overrides the bundled one.
- **Updates:** turn background refresh on/off; turn notifications on/off; run in
  background.
- **Storage:** cache size, "Clear Image Cache", export/import.
- No in-app theme switcher. The app follows the system style, as the HIG
  recommends.

## Non-goals

- Streaming, downloading or linking to pirated sources.
- Social features, accounts, sync servers. Sync could come later through
  export/import or a synced folder.
- Supporting non-TMDB metadata sources in the first releases. The code will
  keep the provider behind an interface so this stays possible.

## Technical notes

- **Stack:** Vala, GTK 4, libadwaita ≥ 1.8, Blueprint, Meson, Flatpak
  (GNOME 50 runtime).
- **Libraries:** libsoup 3 (HTTP), json-glib (JSON), sqlite3 (storage),
  GSettings (preferences), GNotification.
- **Layers:**
  - `models/`: GObject models (`Title`, `Movie`, `Show`, `Season`, `Episode`,
    `WatchEvent`).
  - `services/`: `TmdbClient`, `Database`, `ImageCache`, `Library` (single
    source of truth; exposes `GListModel`s the UI binds to), `RefreshService`,
    `NotificationService`.
  - `pages/`, `dialogs/`, `widgets/`: UI, each a Vala class + Blueprint
    template.
- **Rate limiting:** TMDB allows ~40 requests/s. The client keeps a small
  request queue and uses `append_to_response` to cut down on round trips.
- **Images:** loaded asynchronously as `Gdk.Texture`, with a placeholder until
  they arrive; cached on disk by TMDB path and size.
- **Attribution:** the TMDB logo and notice in About, as TMDB's terms require.
