namespace Pipoca {
    public struct KodiSyncResult {
        public int titles_added;
        public int events_added;
        /* Titles that couldn't be matched to TMDB */
        public int titles_unmatched;
    }

    /**
     * Applies Kodi's library to ours. One-way and additive:
     *
     *  - A Kodi title is added to the library the first time a sync sees it.
     *    If the user removes it later, it stays removed.
     *  - Movies and episodes Kodi has played get a watch event at Kodi's
     *    last-played time, unless they already have one.
     *  - Nothing is ever removed, and nothing is sent to Kodi.
     */
    namespace KodiImport {
        /* Items must have their TMDB ids resolved; those without one are skipped */
        public KodiSyncResult apply (Library library, GenericArray<KodiItem> movies,
                                     GenericArray<KodiItem> shows, GenericArray<KodiItem> episodes) throws Error {
            var result = KodiSyncResult ();
            var db = library.db;
            var touched = new GenericArray<Title> ();
            var shows_by_kodi_id = new HashTable<int64?, Title> (int64_hash, int64_equal);
            var now = new DateTime.now_utc ().to_unix ();

            db.begin ();
            try {
                foreach (var m in movies) {
                    var t = import_title (library, m, ref result);
                    if (t == null) {
                        continue;
                    }
                    if (m.watched && !db.has_watch_events (MediaType.MOVIE, t.id, -1, -1)) {
                        db.add_watch_event (MediaType.MOVIE, t.id, -1, -1, m.last_played > 0 ? m.last_played : now);
                        result.events_added++;
                    }
                    touched.add (t);
                }
                foreach (var s in shows) {
                    var t = import_title (library, s, ref result);
                    if (t != null) {
                        shows_by_kodi_id[s.kodi_id] = t;
                        touched.add (t);
                    }
                }
                foreach (var e in episodes) {
                    var show = shows_by_kodi_id[e.kodi_id];
                    if (show == null || !e.watched || e.season < 0 || e.episode < 0) {
                        continue;
                    }
                    if (!db.has_watch_events (MediaType.TV, show.id, e.season, e.episode)) {
                        db.add_watch_event (MediaType.TV, show.id, e.season, e.episode, e.last_played > 0 ? e.last_played : now);
                        result.events_added++;
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

        /* Returns the title if it's in the library */
        private Title? import_title (Library library, KodiItem item, ref KodiSyncResult result) throws Error {
            if (item.tmdb_id <= 0) {
                result.titles_unmatched++;
                return null;
            }
            var first_time = library.db.mark_kodi_seen (item.media_type, item.tmdb_id);
            var t = library.lookup (item.media_type, item.tmdb_id);
            if (t == null) {
                t = library.intern (new Title (item.media_type, item.tmdb_id));
                // Shown until the details are fetched
                t.name = item.title;
                if (item.year > 0) {
                    t.release_date = "%04d".printf (item.year);
                }
            }
            if (first_time && !t.in_library) {
                if (item.date_added > 0) {
                    t.added_at = item.date_added;
                }
                library.add (t, false);
                result.titles_added++;
            }
            return t.in_library ? t : null;
        }
    }

    /**
     * Keeps the library in sync with Kodi: shortly after startup, then
     * periodically while the app runs. The password lives in the keyring.
     */
    public class KodiSync : Object {
        private static KodiSync? instance;
        private static Secret.Schema? secret_schema;

        private Settings settings;
        private uint timeout_id = 0;
        private HashTable<string, int64?> id_cache = new HashTable<string, int64?> (str_hash, str_equal);

        public bool syncing { get; private set; }
        /* Message of the last failed sync, or null if it succeeded */
        public string? last_error { get; private set; }

        public signal void finished (KodiSyncResult result);

        public static KodiSync get_default () {
            if (instance == null) {
                instance = new KodiSync ();
            }
            return instance;
        }

        construct {
            settings = new Settings (Config.APPLICATION_ID);
            settings.changed["kodi-enabled"].connect (reschedule);
            settings.changed["kodi-sync-interval"].connect (reschedule);
        }

        private static unowned Secret.Schema get_schema () {
            if (secret_schema == null) {
                secret_schema = new Secret.Schema ("io.github.jonnsl.Pipoca.Kodi", Secret.SchemaFlags.NONE,
                                                   "account", Secret.SchemaAttributeType.STRING);
            }
            return secret_schema;
        }

        public async string? get_password () throws Error {
            return yield Secret.password_lookup (get_schema (), null, "account", "kodi");
        }

        public async void set_password (string password) throws Error {
            if (password == "") {
                yield Secret.password_clear (get_schema (), null, "account", "kodi");
                return;
            }
            yield Secret.password_store (get_schema (), Secret.COLLECTION_DEFAULT, _("Pipoca Kodi password"),
                                         password, null, "account", "kodi");
        }

        public int64 last_sync {
            get { return settings.get_int64 ("kodi-last-sync"); }
        }

        /* Starts periodic syncing; call once at startup */
        public void start () {
            reschedule ();
            if (!settings.get_boolean ("kodi-enabled")) {
                return;
            }
            var interval = settings.get_int ("kodi-sync-interval") * 60;
            if (new DateTime.now_utc ().to_unix () - last_sync >= interval) {
                // Let the window show up first
                Timeout.add_seconds (5, () => {
                    sync_quietly ();
                    return Source.REMOVE;
                });
            }
        }

        private void reschedule () {
            if (timeout_id != 0) {
                Source.remove (timeout_id);
                timeout_id = 0;
            }
            if (!settings.get_boolean ("kodi-enabled")) {
                return;
            }
            var minutes = settings.get_int ("kodi-sync-interval");
            timeout_id = Timeout.add_seconds ((uint) minutes * 60, () => {
                sync_quietly ();
                return Source.CONTINUE;
            });
        }

        private void sync_quietly () {
            if (syncing || !NetworkMonitor.get_default ().network_available) {
                return;
            }
            sync.begin (null, (obj, res) => {
                try {
                    sync.end (res);
                } catch (Error e) {
                    warning ("Kodi sync failed: %s", e.message);
                }
            });
        }

        public async KodiSyncResult sync (Cancellable? cancellable = null) throws Error {
            if (syncing) {
                throw new IOError.PENDING (_("A sync is already running"));
            }
            syncing = true;
            try {
                var password = yield get_password ();
                var client = new KodiClient (settings.get_string ("kodi-address"),
                                             settings.get_string ("kodi-username"), password);
                var movies = yield client.get_movies (cancellable);
                var shows = yield client.get_shows (cancellable);
                var episodes = yield client.get_episodes (cancellable);

                var library = Library.get_default ();
                foreach (var item in movies) {
                    yield resolve (library.tmdb, item, cancellable);
                }
                foreach (var item in shows) {
                    yield resolve (library.tmdb, item, cancellable);
                }

                var result = KodiImport.apply (library, movies, shows, episodes);
                settings.set_int64 ("kodi-last-sync", new DateTime.now_utc ().to_unix ());
                last_error = null;
                finished (result);
                if (result.titles_added > 0) {
                    // New titles only have a name; fetch their details
                    library.refresh_library.begin (false);
                }
                return result;
            } catch (Error e) {
                last_error = e.message;
                throw e;
            } finally {
                syncing = false;
            }
        }

        /* Fills in the TMDB id from the IMDb or TVDB id when Kodi doesn't have it */
        private async void resolve (TmdbClient tmdb, KodiItem item, Cancellable? cancellable) {
            if (item.tmdb_id > 0) {
                return;
            }
            string?[] sources = { "imdb_id", item.imdb_id, "tvdb_id", item.media_type == MediaType.TV ? item.tvdb_id : null };
            for (var i = 0; i < sources.length; i += 2) {
                var id = sources[i + 1];
                if (id == null || id == "") {
                    continue;
                }
                var key = "%s:%s:%s".printf (item.media_type.to_api_string (), sources[i], id);
                var cached = id_cache[key];
                if (cached != null) {
                    item.tmdb_id = cached;
                } else {
                    try {
                        item.tmdb_id = yield tmdb.find_by_external_id (sources[i], id, item.media_type, cancellable);
                        id_cache[key] = item.tmdb_id;
                    } catch (Error e) {
                        debug ("Can't look up %s %s: %s", sources[i], id, e.message);
                    }
                }
                if (item.tmdb_id > 0) {
                    return;
                }
            }
        }
    }
}
