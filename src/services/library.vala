namespace Aperture {
    /**
     * The single source of truth for the user's library.
     *
     * Every Title the UI sees goes through {@link intern}, so there's one
     * object per title and property changes show up everywhere.
     */
    public class Library : Object {
        private const int64 REFRESH_INTERVAL = TimeSpan.DAY / TimeSpan.SECOND;
        /* Seasons near the end are refreshed every time; earlier ones only when they change */
        private const int RECENT_SEASONS = 2;
        /* Meta key for the TMDB language the stored metadata was fetched in */
        private const string LANGUAGE_KEY = "metadata_language";

        private static Library? instance;

        public Database db { get; private set; }
        private HashTable<string, Title> titles_by_key = new HashTable<string, Title> (str_hash, str_equal);
        private HashTable<string, Cancellable> refreshing = new HashTable<string, Cancellable> (str_hash, str_equal);
        /* Titles whose "new" badge the user has seen this session */
        private GenericSet<string> seen = new GenericSet<string> (str_hash, str_equal);

        public TmdbClient tmdb { get; private set; }

        /* Titles in the library */
        public ListStore titles { get; private set; }

        public bool refreshing_library { get; private set; }

        /**
         * Episodes and releases after this date ("YYYY-MM-DD") are new, so
         * their titles get a badge; null for none. The app sets it to the day
         * the user last opened it.
         */
        public string? new_since {
            get { return _new_since; }
            set {
                _new_since = value;
                seen.remove_all ();
                for (uint i = 0; i < titles.get_n_items (); i++) {
                    update_progress ((Title) titles.get_item (i));
                }
            }
        }
        private string? _new_since;

        /* Emitted when a title's status, progress or library membership changes */
        public signal void title_changed (Title title);

        public static Library get_default () {
            if (instance == null) {
                instance = new Library ();
            }
            return instance;
        }

        construct {
            tmdb = new TmdbClient ();
            titles = new ListStore (typeof (Title));
            var path = Path.build_filename (Environment.get_user_data_dir (), "aperture", "library.db");
            try {
                db = new Database (path);
                foreach (var t in db.load_library ()) {
                    titles_by_key[t.key] = t;
                    update_progress (t);
                    titles.append (t);
                }
                // Libraries from before the language was recorded are in the current one
                if (db.get_meta (LANGUAGE_KEY) == null) {
                    db.set_meta (LANGUAGE_KEY, tmdb.language);
                }
            } catch (Error e) {
                critical ("Can't open the library database: %s", e.message);
            }
        }

        /* Returns the canonical object for a title, creating one if needed */
        public Title intern (Title t) {
            var existing = lookup (t.media_type, t.id);
            if (existing != null) {
                if (!existing.has_details && existing.name == "") {
                    existing.name = t.name;
                }
                return existing;
            }
            titles_by_key[t.key] = t;
            return t;
        }

        /* Finds a title in memory or in the database */
        public Title? lookup (MediaType type, int64 id) {
            var t = titles_by_key[Title.make_key (type, id)];
            if (t != null) {
                return t;
            }
            try {
                t = db.load_title (type, id);
            } catch (Error e) {
                warning ("Can't load title: %s", e.message);
            }
            if (t != null) {
                titles_by_key[t.key] = t;
                update_progress (t);
            }
            return t;
        }

        /* Lookup that only checks titles already in memory; cheap enough for list rows */
        public bool contains (MediaType type, int64 id) {
            var t = titles_by_key[Title.make_key (type, id)];
            return t != null && t.in_library;
        }

        private void save (Title t) {
            try {
                db.save_title (t);
            } catch (Error e) {
                critical ("Can't save title %s: %s", t.key, e.message);
            }
        }

        /* Adds a title; with @fetch, its details are downloaded if missing */
        public void add (Title title, bool fetch = true) {
            var t = intern (title);
            if (t.in_library) {
                return;
            }
            t.in_library = true;
            if (t.added_at == 0) {
                t.added_at = new DateTime.now_utc ().to_unix ();
            }
            save (t);
            titles.append (t);
            update_progress (t);
            title_changed (t);
            if (fetch && !t.has_details) {
                refresh.begin (t, false, null, false, (obj, res) => {
                    try {
                        refresh.end (res);
                    } catch (Error e) {
                        warning ("Can't fetch details for %s: %s", t.key, e.message);
                    }
                });
            }
        }

        public void remove (Title t) {
            if (!t.in_library) {
                return;
            }
            t.in_library = false;
            // Adding it again later starts fresh; undo restores this itself
            t.dropped_at = 0;
            save (t);
            uint pos;
            if (titles.find (t, out pos)) {
                titles.remove (pos);
            }
            update_progress (t);
            title_changed (t);
        }

        /* ---- Watch progress ---- */

        public void update_progress (Title t) {
            try {
                t.freeze_notify ();
                t.last_watched_at = db.last_watched_at (t.media_type, t.id);
                if (t.is_movie) {
                    t.movie_watched = db.movie_watched (t.id);
                    t.status = !t.in_library ? TitleStatus.NONE
                        : t.movie_watched ? TitleStatus.WATCHED : TitleStatus.PLAN_TO_WATCH;
                } else {
                    int total, aired, watched;
                    db.count_show_progress (t.id, out total, out aired, out watched);
                    t.total_count = total;
                    t.aired_count = aired;
                    t.watched_count = watched;
                    t.next_episode = db.find_next_episode (t.id);
                    t.upcoming_episode = db.find_upcoming_episode (t.id);
                    if (!t.in_library) {
                        t.status = TitleStatus.NONE;
                    } else if (watched == 0) {
                        t.status = TitleStatus.PLAN_TO_WATCH;
                    } else if (watched < aired) {
                        t.status = TitleStatus.WATCHING;
                    } else if (t.is_ended && watched >= total) {
                        t.status = TitleStatus.WATCHED;
                    } else {
                        t.status = TitleStatus.UP_TO_DATE;
                    }
                }
                // The user's choice wins over progress
                if (t.in_library && t.is_dropped) {
                    t.status = TitleStatus.DROPPED;
                }
                t.has_new = is_new (t);
            } catch (Error e) {
                warning ("Can't compute progress of %s: %s", t.key, e.message);
            } finally {
                t.thaw_notify ();
            }
        }

        private bool is_new (Title t) throws Error {
            if (new_since == null || !t.in_library || t.is_dropped || t.key in seen) {
                return false;
            }
            if (t.is_movie) {
                var date = t.release_date;
                return t.status == TitleStatus.PLAN_TO_WATCH && date != null && date.length == 10
                    && date > new_since && date <= Utils.today ();
            }
            return db.has_new_episodes (t.id, new_since);
        }

        /* Clears a title's "new" badge until the next session */
        public void mark_seen (Title t) {
            seen.add (t.key);
            t.has_new = false;
        }

        public void set_movie_watched (Title t, bool watched) {
            return_if_fail (t.is_movie);
            try {
                if (watched) {
                    if (!t.movie_watched) {
                        db.add_watch_event (MediaType.MOVIE, t.id, -1, -1, new DateTime.now_utc ().to_unix ());
                    }
                } else {
                    db.remove_watch_events (MediaType.MOVIE, t.id, -1, -1);
                }
            } catch (Error e) {
                critical ("Can't save watch event: %s", e.message);
            }
            after_watch_change (t, watched);
        }

        /**
         * Marks episodes watched or unwatched. Returns the episodes whose state
         * actually changed, so the caller can undo.
         */
        public GenericArray<Episode> set_episodes_watched (Title show, GenericArray<Episode> episodes, bool watched) {
            var changed = new GenericArray<Episode> ();
            var now = new DateTime.now_utc ().to_unix ();
            try {
                db.begin ();
                foreach (var e in episodes) {
                    if (e.watched == watched) {
                        continue;
                    }
                    if (watched) {
                        db.add_watch_event (MediaType.TV, show.id, e.season_number, e.episode_number, now);
                    } else {
                        db.remove_watch_events (MediaType.TV, show.id, e.season_number, e.episode_number);
                    }
                    changed.add (e);
                }
                db.commit ();
            } catch (Error e) {
                db.rollback ();
                critical ("Can't save watch events: %s", e.message);
                return new GenericArray<Episode> ();
            }
            foreach (var e in changed) {
                e.watched = watched;
            }
            after_watch_change (show, watched);
            episodes_changed (show);
            return changed;
        }

        /* Emitted when episodes of a show are marked, so open pages can reload */
        public signal void episodes_changed (Title show);

        private void after_watch_change (Title t, bool watched) {
            // Watching something counts as adding it
            if (watched && !t.in_library) {
                add (t);
                return;
            }
            // ...and as picking a dropped title back up
            if (watched && t.is_dropped) {
                t.dropped_at = 0;
                save (t);
            }
            update_progress (t);
            title_changed (t);
        }

        /**
         * Drops a title (started, won't finish) or picks it back up.
         * @dropped_at is the time to record; 0 means now.
         */
        public void set_dropped (Title t, bool dropped, int64 dropped_at = 0) {
            return_if_fail (t.in_library);
            if (dropped == t.is_dropped) {
                return;
            }
            t.dropped_at = dropped ? (dropped_at > 0 ? dropped_at : new DateTime.now_utc ().to_unix ()) : 0;
            save (t);
            update_progress (t);
            title_changed (t);
        }

        /* Turns "Notify Me" on or off for a title */
        public void set_notify (Title t, bool enabled) {
            if (t.notify_enabled == enabled) {
                return;
            }
            t.notify_enabled = enabled;
            if (t.in_library) {
                save (t);
            }
        }

        /* Aired episodes up to and including @episode, for "mark watched up to here" */
        public GenericArray<Episode> get_episodes_up_to (Title show, Episode episode) {
            try {
                return db.load_aired_episodes_up_to (show.id, episode.season_number, episode.episode_number);
            } catch (Error e) {
                critical ("Can't load episodes: %s", e.message);
                return new GenericArray<Episode> ();
            }
        }

        public GenericArray<Season> get_seasons (Title show) {
            try {
                return db.load_seasons (show.id);
            } catch (Error e) {
                critical ("Can't load seasons: %s", e.message);
                return new GenericArray<Season> ();
            }
        }

        public GenericArray<Episode> get_episodes (Title show, int season_number) {
            try {
                return db.load_episodes (show.id, season_number);
            } catch (Error e) {
                critical ("Can't load episodes: %s", e.message);
                return new GenericArray<Episode> ();
            }
        }

        /**
         * Episodes of shows in the library and releases of movies on the
         * watchlist from @from to @until ("YYYY-MM-DD", inclusive; null for no
         * end), by date. Dropped titles are left out.
         */
        public GenericArray<Release> get_releases (string from, string? until = null) {
            var result = new GenericArray<Release> ();
            try {
                foreach (var e in db.load_episodes_airing (from, until)) {
                    var show = titles_by_key[Title.make_key (MediaType.TV, e.show_id)];
                    if (show != null) {
                        result.add (new Release (show, e));
                    }
                }
            } catch (Error e) {
                critical ("Can't load upcoming episodes: %s", e.message);
            }
            for (uint i = 0; i < titles.get_n_items (); i++) {
                var t = (Title) titles.get_item (i);
                // Imported titles may only have a year until they're refreshed
                var date = t.release_date;
                if (t.is_movie && t.status == TitleStatus.PLAN_TO_WATCH && date != null && date.length == 10
                    && date >= from && (until == null || date <= until)) {
                    result.add (new Release (t));
                }
            }
            result.sort ((a, b) => {
                var c = strcmp (a.date, b.date);
                if (c == 0) {
                    c = a.title.name.collate (b.title.name);
                }
                if (c == 0 && a.episode != null && b.episode != null) {
                    c = a.episode.season_number != b.episode.season_number
                        ? a.episode.season_number - b.episode.season_number
                        : a.episode.episode_number - b.episode.episode_number;
                }
                return c;
            });
            return result;
        }

        /* ---- Refreshing from TMDB ---- */

        public bool is_stale (Title t) {
            return new DateTime.now_utc ().to_unix () - t.refreshed_at > REFRESH_INTERVAL;
        }

        /**
         * Fetches a title's metadata (and a show's seasons) from TMDB.
         * Concurrent calls for the same title share one request.
         */
        public async void refresh (Title t, bool force = false, Cancellable? cancellable = null,
                                   bool all_seasons = false) throws Error {
            if (!force && !is_stale (t)) {
                return;
            }
            if (refreshing.contains (t.key)) {
                // Wait for the refresh in progress
                ulong id = 0;
                id = refresh_finished.connect ((finished) => {
                    if (finished == t) {
                        disconnect (id);
                        Idle.add (refresh.callback);
                    }
                });
                yield;
                return;
            }
            var c = cancellable ?? new Cancellable ();
            refreshing[t.key] = c;
            try {
                var details = yield tmdb.get_details (t.media_type, t.id, c);
                t.update_from_json (details);
                if (!t.is_movie) {
                    yield refresh_seasons (t, details, c, all_seasons);
                }
                t.refreshed_at = new DateTime.now_utc ().to_unix ();
                save (t);
                update_progress (t);
                title_changed (t);
                if (!t.is_movie) {
                    episodes_changed (t);
                }
            } finally {
                refreshing.remove (t.key);
                // Wakes up waiters even if this refresh failed
                refresh_finished (t);
            }
        }

        private signal void refresh_finished (Title t);

        /* With @all, every season is fetched, e.g. for another language; otherwise only those that may have changed */
        private async void refresh_seasons (Title show, Json.Object details, Cancellable c, bool all) throws Error {
            var seasons = new GenericArray<Season> ();
            var arr = JsonUtil.array (details, "seasons");
            if (arr != null) {
                arr.foreach_element ((a, i, node) => {
                    if (node.get_node_type () == Json.NodeType.OBJECT) {
                        seasons.add (Season.from_json (show.id, node.get_object ()));
                    }
                });
            }

            var stored = db.count_episodes (show.id);
            var max_season = 0;
            foreach (var s in seasons) {
                max_season = int.max (max_season, s.season_number);
            }
            int[] wanted = {};
            foreach (var s in seasons) {
                if (all || !stored.contains (s.season_number)
                    || stored[s.season_number] != s.episode_count
                    || s.season_number > max_season - RECENT_SEASONS) {
                    wanted += s.season_number;
                }
            }

            var fetched = yield tmdb.get_seasons (show.id, wanted, c);

            db.begin ();
            try {
                db.save_seasons (show.id, seasons);
                foreach (var obj in fetched) {
                    var number = (int) JsonUtil.integer (obj, "season_number");
                    var episodes = new GenericArray<Episode> ();
                    var eps = JsonUtil.array (obj, "episodes");
                    if (eps != null) {
                        eps.foreach_element ((a, i, node) => {
                            if (node.get_node_type () == Json.NodeType.OBJECT) {
                                episodes.add (Episode.from_json (show.id, node.get_object ()));
                            }
                        });
                    }
                    db.save_episodes (show.id, number, episodes);
                }
                db.commit ();
            } catch (Error e) {
                db.rollback ();
                throw e;
            }
        }

        /* Whether the stored metadata is in another language than TMDB requests use now */
        public bool needs_relocalizing () {
            try {
                return db.get_meta (LANGUAGE_KEY) != tmdb.language;
            } catch (Error e) {
                warning ("Can't read the library language: %s", e.message);
                return false;
            }
        }

        /**
         * Refreshes stale titles in the library, at most once a day each.
         * Shows that are still airing go first since they change the most.
         *
         * After the metadata language changes, everything is refreshed
         * instead, every season included, until a refresh gets through.
         */
        public async void refresh_library (bool force = false) {
            if (refreshing_library) {
                return;
            }
            refreshing_library = true;
            var language = tmdb.language;
            var relocalize = needs_relocalizing ();
            force = force || relocalize;
            var queue = new GenericArray<Title> ();
            for (uint i = 0; i < titles.get_n_items (); i++) {
                var t = (Title) titles.get_item (i);
                // Nothing to keep up with for dropped titles, unless asked
                if (force || (is_stale (t) && !t.is_dropped)) {
                    queue.add (t);
                }
            }
            queue.sort ((a, b) => {
                var pa = refresh_priority (a);
                var pb = refresh_priority (b);
                if (pa != pb) {
                    return pa - pb;
                }
                return (int) (a.refreshed_at - b.refreshed_at).clamp (-1, 1);
            });

            // A few at a time; the TMDB client queues the rest
            var pending = 0;
            var next = 0;
            var failures = 0;
            SourceFunc done = refresh_library.callback;
            var finished = false;

            Thunk? start_more = null;
            start_more = () => {
                while (pending < 4 && next < queue.length && failures < 5) {
                    var t = queue[next++];
                    pending++;
                    refresh.begin (t, true, null, relocalize, (obj, res) => {
                        try {
                            refresh.end (res);
                        } catch (Error e) {
                            failures++;
                            warning ("Can't refresh %s: %s", t.key, e.message);
                        }
                        pending--;
                        start_more ();
                    });
                }
                if (pending == 0 && !finished) {
                    finished = true;
                    Idle.add ((owned) done);
                }
            };
            start_more ();
            yield;
            // Only once all of it is in the new language; the next refresh tries again
            if (relocalize && failures == 0) {
                try {
                    db.set_meta (LANGUAGE_KEY, language);
                } catch (Error e) {
                    warning ("Can't save the library language: %s", e.message);
                }
            }
            refreshing_library = false;
        }

        private delegate void Thunk ();

        private static int refresh_priority (Title t) {
            if (!t.is_movie && !t.is_ended) {
                return 0;
            }
            return t.has_details ? 2 : 1;
        }
    }
}
