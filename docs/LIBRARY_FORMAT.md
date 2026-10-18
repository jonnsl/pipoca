# Library File Format

Pipoca can export your library to a JSON file and import it back
(Preferences → Advanced → Library). Use it for backups, to move your library
to another computer, or to read your data with other tools.

The file is UTF-8 JSON. This document describes **version 1**.

## Example

```json
{
  "format": "pipoca-library",
  "version": 1,
  "exported_at": "2026-10-17T05:30:00Z",
  "titles": [
    {
      "media_type": "tv",
      "tmdb_id": 95396,
      "name": "Severance",
      "release_date": "2022-02-17",
      "poster_path": "/pPHpeI2X1qEd1CS1SeyrdhZ4qnT.jpg",
      "added_at": "2026-10-17T05:00:00Z",
      "watched": [
        { "season": 1, "episode": 1, "watched_at": "2026-10-17T05:10:00Z" },
        { "season": 1, "episode": 2, "watched_at": "2026-10-17T05:20:00Z" }
      ]
    },
    {
      "media_type": "movie",
      "tmdb_id": 693134,
      "name": "Dune: Part Two",
      "release_date": "2024-02-27",
      "added_at": "2026-10-17T05:00:00Z",
      "watched": [
        { "watched_at": "2026-10-17T05:25:00Z" }
      ]
    }
  ]
}
```

## Top level

| Member        | Type   | Required | Description                                          |
|---------------|--------|----------|------------------------------------------------------|
| `format`      | string | yes      | Always `"pipoca-library"`.                         |
| `version`     | number | yes      | Format version. Currently `1`.                       |
| `exported_at` | string | no       | When the file was written (timestamp, see below).    |
| `titles`      | array  | yes      | The titles in the library, as *title* objects.       |

## Title

A movie or TV show in the library. [TMDB](https://www.themoviedb.org/) ids
identify titles, so `media_type` plus `tmdb_id` must be unique in a file.

| Member         | Type   | Required | Description                                                                   |
|----------------|--------|----------|-------------------------------------------------------------------------------|
| `media_type`   | string | yes      | `"movie"` or `"tv"`.                                                          |
| `tmdb_id`      | number | yes      | The TMDB id: `https://www.themoviedb.org/<media_type>/<tmdb_id>`.             |
| `name`         | string | no       | Title in the language the metadata was fetched in.                            |
| `release_date` | string | no       | Release date (movies) or first air date (shows), `YYYY-MM-DD`.                |
| `poster_path`  | string | no       | TMDB image path of the poster.                                                |
| `added_at`     | string | no       | When the title was added to the library (timestamp).                          |
| `dropped_at`   | string | no       | When the user dropped the title (started it, won't finish). Absent otherwise. |
| `notify`       | bool   | no       | `false` when the user turned off notifications for the title. Default `true`. |
| `watched`      | array  | no       | Watch events, as *watch event* objects.                                       |

`name`, `release_date` and `poster_path` are only a snapshot so the library
looks right before Pipoca downloads the full details from TMDB. Imports
never use them to overwrite details Pipoca already has.

## Watch event

One viewing of a movie or an episode. A title or episode watched more than
once has one event per viewing.

| Member       | Type   | Required    | Description                                                  |
|--------------|--------|-------------|--------------------------------------------------------------|
| `season`     | number | shows only  | Season number. `0` is TMDB's "Specials" season.              |
| `episode`    | number | shows only  | Episode number within the season.                            |
| `watched_at` | string | yes         | When it was watched (timestamp).                             |

Movie events have no `season` or `episode`.

## Timestamps

ISO 8601 date and time. Pipoca writes UTC with a `Z` suffix, e.g.
`2026-10-17T05:30:00Z`. Imports accept any offset, e.g.
`2026-10-17T02:30:00-03:00`.

## Import rules

Importing **merges** the file into the library; it never removes or
overwrites anything:

- Titles that aren't in the library are added, keeping `added_at`,
  `dropped_at` and `notify` when present. Titles already in the library keep
  their dropped and notification settings.
- Watch events are added unless an identical one (same episode and
  `watched_at`) already exists, so importing the same file twice is harmless.
- Titles with an unknown `media_type` or an invalid `tmdb_id` are skipped.
  So are show events missing `season` or `episode`, and events without a
  valid `watched_at`.
- Unknown members are ignored, so newer files with extra data still import.
- A file whose `version` is newer than the app supports is rejected.

After an import, Pipoca downloads the details of the new titles from TMDB
the next time it's online.
