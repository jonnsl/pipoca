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

        private static Library? instance;

        public Database db { get; private set; }
        private HashTable<string, Title> titles_by_key = new HashTable<string, Title> (str_hash, str_equal);
        private HashTable<string, Cancellable> refreshing = new HashTable<string, Cancellable> (str_hash, str_equal);

        public TmdbClient tmdb { get; private set; }

        /* Titles in the library */
        public ListStore titles { get; private set; }

        public bool refreshing_library { get; private set; }

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

        public void add (Title title) {
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
            if (!t.has_details) {
                refresh.begin (t, false, null, (obj, res) => {
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
            } catch (Error e) {
                warning ("Can't compute progress of %s: %s", t.key, e.message);
            } finally {
                t.thaw_notify ();
            }
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
            update_progress (t);
            title_changed (t);
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

        /* ---- Refreshing from TMDB ---- */

        public bool is_stale (Title t) {
            return new DateTime.now_utc ().to_unix () - t.refreshed_at > REFRESH_INTERVAL;
        }

        /**
         * Fetches a title's metadata (and a show's seasons) from TMDB.
         * Concurrent calls for the same title share one request.
         */
        public async void refresh (Title t, bool force = false, Cancellable? cancellable = null) throws Error {
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
                    yield refresh_seasons (t, details, c);
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

        private async void refresh_seasons (Title show, Json.Object details, Cancellable c) throws Error {
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
                if (!stored.contains (s.season_number)
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

        /**
         * Refreshes stale titles in the library, at most once a day each.
         * Shows that are still airing go first since they change the most.
         */
        public async void refresh_library (bool force = false) {
            if (refreshing_library) {
                return;
            }
            refreshing_library = true;
            var queue = new GenericArray<Title> ();
            for (uint i = 0; i < titles.get_n_items (); i++) {
                var t = (Title) titles.get_item (i);
                if (force || is_stale (t)) {
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
                    refresh.begin (t, true, null, (obj, res) => {
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
