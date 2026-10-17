namespace Aperture {
    /* What an IMDb CSV export holds */
    public enum ImdbFileKind {
        /* "Your Ratings": titles the user rated, with the date */
        RATINGS,
        /* The watchlist or another list, with the date each title was added */
        LIST,
    }

    /* A row of an IMDb export */
    public class ImdbItem {
        public string imdb_id;
        public string title;
        /* Rated or added to the list (Unix time), or 0 */
        public int64 date;
        /* Set by the TMDB lookup when found */
        public ImdbMatch? match;
    }

    /* An IMDb title found on TMDB: a movie, a show, or an episode of a show */
    public class ImdbMatch {
        public MediaType media_type;
        public int64 tmdb_id;
        /* -1 unless it's an episode */
        public int season = -1;
        public int episode = -1;
        public int64 date;
        /* TMDB's search-style result, to show the title until its details are fetched */
        public Json.Object? summary;

        public bool is_episode {
            get { return season >= 0 && episode >= 0; }
        }
    }

    /**
     * Imports IMDb's CSV exports. IMDb has no watch history, so the ratings
     * export stands in for it, with the date rated as the date watched.
     * Like library files, imports only add: titles missing from the library
     * and watches of movies and episodes that have none.
     */
    namespace ImdbImport {
        public delegate void ProgressFunc (int done, int total);

        /* How many TMDB lookups run at once; the TMDB client queues the rest */
        private const int MAX_LOOKUPS = 8;

        public ImdbFileKind parse (string data, out GenericArray<ImdbItem> items) throws Error {
            items = new GenericArray<ImdbItem> ();
            var rows = parse_csv (data);
            if (rows.length == 0) {
                throw new TransferError.INVALID_FORMAT (_("This isn’t an IMDb export"));
            }
            var header = new HashTable<string, int> (str_hash, str_equal);
            for (var i = 0; i < rows[0].length; i++) {
                header[rows[0][i].strip ()] = i;
            }
            if (!header.contains ("Const")) {
                throw new TransferError.INVALID_FORMAT (_("This isn’t an IMDb export"));
            }
            ImdbFileKind kind;
            string date_column;
            if (header.contains ("Position")) {
                kind = ImdbFileKind.LIST;
                date_column = "Created";
            } else if (header.contains ("Date Rated")) {
                kind = ImdbFileKind.RATINGS;
                date_column = "Date Rated";
            } else {
                throw new TransferError.INVALID_FORMAT (_("This isn’t an IMDb ratings or list export"));
            }

            var seen = new GenericSet<string> (str_hash, str_equal);
            for (var r = 1; r < rows.length; r++) {
                var id = cell (rows[r], header, "Const");
                if (id == null || !Regex.match_simple ("^tt[0-9]+$", id) || id in seen) {
                    continue;
                }
                seen.add (id);
                items.add (new ImdbItem () {
                    imdb_id = id,
                    title = cell (rows[r], header, "Title") ?? "",
                    date = parse_date (cell (rows[r], header, date_column)),
                });
            }
            return kind;
        }

        private string? cell (GenericArray<string> row, HashTable<string, int> header, string column) {
            if (!header.contains (column)) {
                return null;
            }
            var i = header[column];
            return i < row.length ? row[i].strip () : null;
        }

        /* "2024-05-14", taken as midday local time so the day stays the same in any time zone */
        private int64 parse_date (string? s) {
            if (s == null || s.length < 10) {
                return 0;
            }
            var dt = new DateTime.from_iso8601 (s.substring (0, 10) + "T12:00:00", new TimeZone.local ());
            return dt != null ? dt.to_unix () : 0;
        }

        /* RFC 4180: quoted fields may hold commas, line breaks and doubled quotes */
        public GenericArray<GenericArray<string>> parse_csv (string data) {
            var rows = new GenericArray<GenericArray<string>> ();
            var row = new GenericArray<string> ();
            var field = new StringBuilder ();
            var quoted = false;
            var start = data.has_prefix ("\uFEFF") ? "\uFEFF".length : 0;
            for (var i = start; i < data.length; i++) {
                var c = data[i];
                if (quoted) {
                    if (c == '"') {
                        if (i + 1 < data.length && data[i + 1] == '"') {
                            field.append_c ('"');
                            i++;
                        } else {
                            quoted = false;
                        }
                    } else {
                        field.append_c (c);
                    }
                } else if (c == '"') {
                    quoted = true;
                } else if (c == ',') {
                    row.add (field.str);
                    field.truncate ();
                } else if (c == '\n' || c == '\r') {
                    if (c == '\r' && i + 1 < data.length && data[i + 1] == '\n') {
                        i++;
                    }
                    row.add (field.str);
                    field.truncate ();
                    add_row (rows, row);
                    row = new GenericArray<string> ();
                } else {
                    field.append_c (c);
                }
            }
            if (field.len > 0 || row.length > 0) {
                row.add (field.str);
                add_row (rows, row);
            }
            return rows;
        }

        private void add_row (GenericArray<GenericArray<string>> rows, GenericArray<string> row) {
            // Blank lines
            if (row.length == 1 && row[0] == "") {
                return;
            }
            rows.add (row);
        }

        /**
         * Reads TMDB's /find response for an IMDb id. Episodes count over
         * movies and shows, since their ids only ever match an episode.
         */
        public ImdbMatch? match_from_find (ImdbItem item, Json.Object found) {
            var episodes = JsonUtil.array (found, "tv_episode_results");
            if (episodes != null && episodes.get_length () > 0) {
                var e = episodes.get_object_element (0);
                var show_id = JsonUtil.integer (e, "show_id");
                if (show_id <= 0) {
                    return null;
                }
                return new ImdbMatch () {
                    media_type = MediaType.TV,
                    tmdb_id = show_id,
                    season = (int) JsonUtil.integer (e, "season_number"),
                    episode = (int) JsonUtil.integer (e, "episode_number"),
                    date = item.date,
                };
            }
            string[] members = { "movie_results", "tv_results" };
            MediaType[] types = { MediaType.MOVIE, MediaType.TV };
            for (var i = 0; i < members.length; i++) {
                var results = JsonUtil.array (found, members[i]);
                if (results == null || results.get_length () == 0) {
                    continue;
                }
                var o = results.get_object_element (0);
                var id = JsonUtil.integer (o, "id");
                if (id <= 0) {
                    continue;
                }
                return new ImdbMatch () {
                    media_type = types[i],
                    tmdb_id = id,
                    date = item.date,
                    summary = o,
                };
            }
            return null;
        }

        /* Shared by the lookup workers of one import */
        private class Lookups : Object {
            public GenericArray<ImdbItem> items;
            public Cancellable cancellable = new Cancellable ();
            public int next;
            public int done;
            public Error? failure;

            public signal void progressed ();
        }

        /**
         * Looks up every item on TMDB, setting its match. Items TMDB doesn't
         * know (games, podcasts, missing titles) are left without one. Any
         * other error stops the lookups and is thrown.
         */
        public async void find_all (TmdbClient tmdb, GenericArray<ImdbItem> items, ProgressFunc? progress,
                                    Cancellable? cancellable) throws Error {
            var lookups = new Lookups () { items = items };
            lookups.progressed.connect (() => {
                if (progress != null) {
                    progress (lookups.done, items.length);
                }
            });
            ulong cancel_id = 0;
            if (cancellable != null) {
                cancel_id = cancellable.connect (() => lookups.cancellable.cancel ());
            }
            var running = 0;
            SourceFunc callback = find_all.callback;
            for (var i = 0; i < MAX_LOOKUPS; i++) {
                running++;
                lookup_worker.begin (tmdb, lookups, (obj, res) => {
                    lookup_worker.end (res);
                    if (--running == 0) {
                        Idle.add ((owned) callback);
                    }
                });
            }
            yield;
            if (cancellable != null) {
                cancellable.disconnect (cancel_id);
                cancellable.set_error_if_cancelled ();
            }
            if (lookups.failure != null) {
                throw lookups.failure;
            }
        }

        private async void lookup_worker (TmdbClient tmdb, Lookups lookups) {
            while (!lookups.cancellable.is_cancelled () && lookups.next < lookups.items.length) {
                var item = lookups.items[lookups.next++];
                try {
                    var found = yield tmdb.find ("imdb_id", item.imdb_id, lookups.cancellable);
                    item.match = match_from_find (item, found);
                    lookups.done++;
                    lookups.progressed ();
                } catch (Error e) {
                    if (lookups.failure == null && !(e is IOError.CANCELLED)) {
                        lookups.failure = e;
                        lookups.cancellable.cancel ();
                    }
                    return;
                }
            }
        }

        /**
         * Adds the matches to the library. With @as_watched, movies and
         * episodes get a watch at the item's date unless they have one;
         * otherwise titles are only added, e.g. from the watchlist.
         */
        public ImportResult apply (Library library, GenericArray<ImdbMatch> matches, bool as_watched) throws Error {
            var result = ImportResult ();
            var db = library.db;
            var touched = new GenericArray<Title> ();
            var touched_keys = new GenericSet<string> (str_hash, str_equal);
            var now = new DateTime.now_utc ().to_unix ();

            db.begin ();
            try {
                foreach (var m in matches) {
                    var t = library.lookup (m.media_type, m.tmdb_id);
                    if (t == null) {
                        t = library.intern (new Title (m.media_type, m.tmdb_id));
                    }
                    // Episodes don't come with their show's info; a later row for the show may
                    if (m.summary != null && !t.has_details) {
                        t.update_from_json (m.summary);
                    }
                    if (!t.in_library) {
                        if (m.date > 0) {
                            t.added_at = m.date;
                        }
                        library.add (t, false);
                        result.titles_added++;
                    }
                    if (as_watched && (t.is_movie || m.is_episode)) {
                        var season = t.is_movie ? -1 : m.season;
                        var episode = t.is_movie ? -1 : m.episode;
                        if (!db.has_watch_events (t.media_type, t.id, season, episode)) {
                            db.add_watch_event (t.media_type, t.id, season, episode, m.date > 0 ? m.date : now);
                            result.events_added++;
                        }
                    }
                    if (!(t.key in touched_keys)) {
                        touched_keys.add (t.key);
                        touched.add (t);
                    }
                }
                db.commit ();
            } catch (Error e) {
                db.rollback ();
                throw e;
            }

            foreach (var t in touched) {
                library.update_progress (t);
                library.title_changed (t);
                if (!t.is_movie) {
                    library.episodes_changed (t);
                }
            }
            return result;
        }
    }
}
