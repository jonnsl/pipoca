namespace Pipoca {
    public struct RadarrSyncResult {
        /* Movies added to our library */
        public int titles_added;
        /* Movies added to Radarr */
        public int titles_sent;
        /* Movies Radarr wouldn't take; they're tried again next sync */
        public int titles_failed;
    }

    /**
     * Syncs movies between Radarr and our library. Additive both ways:
     *
     *  - A Radarr movie is added to the library the first time a sync sees it.
     *    If the user removes it later, it stays removed.
     *  - Unless read-only, movies on the watchlist are added to Radarr, once.
     *    If the user removes one from Radarr, it stays removed.
     *  - Nothing is ever removed on either side.
     *
     * Both rules rest on one record of the movies Radarr has had.
     */
    namespace RadarrImport {
        public RadarrSyncResult apply (Library library, GenericArray<RadarrMovie> movies) throws Error {
            var result = RadarrSyncResult ();
            var db = library.db;
            db.begin ();
            try {
                foreach (var m in movies) {
                    if (m.tmdb_id <= 0) {
                        continue;
                    }
                    var first_time = db.mark_radarr_seen (m.tmdb_id);
                    var t = library.lookup (MediaType.MOVIE, m.tmdb_id);
                    if (t == null) {
                        t = library.intern (new Title (MediaType.MOVIE, m.tmdb_id));
                        // Shown until the details are fetched
                        t.name = m.title;
                        if (m.year > 0) {
                            t.release_date = "%04d".printf (m.year);
                        }
                    }
                    if (first_time && !t.in_library) {
                        if (m.date_added > 0) {
                            t.added_at = m.date_added;
                        }
                        library.add (t, false);
                        result.titles_added++;
                    }
                }
                db.commit ();
            } catch (Error e) {
                db.rollback ();
                throw e;
            }
            return result;
        }

        /* Watchlist movies Radarr has never had; call after apply() */
        public GenericArray<Title> to_send (Library library) throws Error {
            var titles = new GenericArray<Title> ();
            for (uint i = 0; i < library.titles.get_n_items (); i++) {
                var t = (Title) library.titles.get_item (i);
                if (t.is_movie && t.status == TitleStatus.PLAN_TO_WATCH && !library.db.radarr_seen (t.id)) {
                    titles.add (t);
                }
            }
            return titles;
        }
    }

    /**
     * Keeps the library in sync with Radarr: shortly after startup, then
     * periodically while the app runs. The API key and password live in the
     * keyring.
     */
    public class RadarrSync : Object {
        private static RadarrSync? instance;
        private static Secret.Schema? secret_schema;

        private Settings settings;
        private uint timeout_id = 0;

        public bool syncing { get; private set; }
        /* Message of the last failed sync, or null if it succeeded */
        public string? last_error { get; private set; }

        public signal void finished (RadarrSyncResult result);

        public static RadarrSync get_default () {
            if (instance == null) {
                instance = new RadarrSync ();
            }
            return instance;
        }

        construct {
            settings = new Settings (Config.APPLICATION_ID);
            settings.changed["radarr-enabled"].connect (reschedule);
            settings.changed["radarr-sync-interval"].connect (reschedule);
        }

        private static unowned Secret.Schema get_schema () {
            if (secret_schema == null) {
                secret_schema = new Secret.Schema ("io.github.jonnsl.Pipoca.Radarr", Secret.SchemaFlags.NONE,
                                                   "account", Secret.SchemaAttributeType.STRING);
            }
            return secret_schema;
        }

        /* @account is "api-key" or "password" */
        public async string? get_secret (string account) throws Error {
            return yield Secret.password_lookup (get_schema (), null, "account", account);
        }

        public async void set_secret (string account, string secret) throws Error {
            if (secret == "") {
                yield Secret.password_clear (get_schema (), null, "account", account);
                return;
            }
            var label = account == "api-key" ? _("Pipoca Radarr API key") : _("Pipoca Radarr password");
            yield Secret.password_store (get_schema (), Secret.COLLECTION_DEFAULT, label, secret, null,
                                         "account", account);
        }

        public int64 last_sync {
            get { return settings.get_int64 ("radarr-last-sync"); }
        }

        public async RadarrClient make_client () throws Error {
            return new RadarrClient (settings.get_string ("radarr-address"), yield get_secret ("api-key"),
                                     settings.get_string ("radarr-username"), yield get_secret ("password"),
                                     settings.get_boolean ("radarr-accept-any-certificate"));
        }

        /* Starts periodic syncing; call once at startup */
        public void start () {
            reschedule ();
            if (!settings.get_boolean ("radarr-enabled")) {
                return;
            }
            var interval = settings.get_int ("radarr-sync-interval") * 60;
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
            if (!settings.get_boolean ("radarr-enabled")) {
                return;
            }
            var minutes = settings.get_int ("radarr-sync-interval");
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
                    warning ("Radarr sync failed: %s", e.message);
                }
            });
        }

        public async RadarrSyncResult sync (Cancellable? cancellable = null) throws Error {
            if (syncing) {
                throw new IOError.PENDING (_("A sync is already running"));
            }
            syncing = true;
            try {
                var client = yield make_client ();
                var movies = yield client.get_movies (cancellable);
                var library = Library.get_default ();
                var result = RadarrImport.apply (library, movies);
                if (!settings.get_boolean ("radarr-read-only")) {
                    result = yield send (client, library, result, cancellable);
                }

                settings.set_int64 ("radarr-last-sync", new DateTime.now_utc ().to_unix ());
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

        /* Adds the watchlist movies Radarr has never had, to the chosen profile and folder */
        private async RadarrSyncResult send (RadarrClient client, Library library, RadarrSyncResult result,
                                             Cancellable? cancellable) throws Error {
            var titles = RadarrImport.to_send (library);
            if (titles.length == 0) {
                return result;
            }

            // Radarr's first ones unless the user picked others it still has
            var profiles = yield client.get_quality_profiles (cancellable);
            if (profiles.length == 0) {
                throw new RadarrError.NOT_CONFIGURED (_("Radarr has no quality profiles"));
            }
            var profile = profiles[0].id;
            var wanted_profile = settings.get_int64 ("radarr-quality-profile");
            foreach (var p in profiles) {
                if (p.id == wanted_profile) {
                    profile = wanted_profile;
                }
            }
            var folders = yield client.get_root_folders (cancellable);
            if (folders.length == 0) {
                throw new RadarrError.NOT_CONFIGURED (_("Radarr has no root folders"));
            }
            var wanted_folder = settings.get_string ("radarr-root-folder");
            var folder = wanted_folder in folders ? wanted_folder : folders[0];

            foreach (var t in titles) {
                try {
                    yield client.add_movie (t.id, profile, folder, cancellable);
                    library.db.mark_radarr_seen (t.id);
                    result.titles_sent++;
                } catch (IOError.CANCELLED e) {
                    throw e;
                } catch (Error e) {
                    warning ("Can't add %s to Radarr: %s", t.key, e.message);
                    result.titles_failed++;
                }
            }
            return result;
        }
    }
}
