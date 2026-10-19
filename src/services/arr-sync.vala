namespace Pipoca {
    public struct ArrSyncResult {
        /* Titles added to our library */
        public int titles_added;
        /* Titles added to Radarr or Sonarr */
        public int titles_sent;
        /* Titles Radarr or Sonarr wouldn't take; they're tried again next sync */
        public int titles_failed;
    }

    /**
     * Syncs titles between Radarr (movies) or Sonarr (shows) and our
     * library. Additive both ways:
     *
     *  - A title there is added to the library the first time a sync sees
     *    it. If the user removes it later, it stays removed.
     *  - Unless read-only, titles the user hasn't finished are added there,
     *    once. If the user removes one there, it stays removed.
     *  - Nothing is ever removed on either side.
     *
     * Both rules rest on one record of the titles Radarr or Sonarr has had.
     */
    namespace ArrImport {
        /* Items must have their TMDB ids resolved; those without one are skipped */
        public ArrSyncResult apply (Library library, MediaType type, GenericArray<ArrItem> items) throws Error {
            var result = ArrSyncResult ();
            var db = library.db;
            db.begin ();
            try {
                foreach (var item in items) {
                    if (item.tmdb_id <= 0) {
                        continue;
                    }
                    var first_time = db.mark_arr_seen (type, item.tmdb_id);
                    var t = library.lookup (type, item.tmdb_id);
                    if (t == null) {
                        t = library.intern (new Title (type, item.tmdb_id));
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
                }
                db.commit ();
            } catch (Error e) {
                db.rollback ();
                throw e;
            }
            return result;
        }

        /* Unfinished titles of @type that were never there; call after apply() */
        public GenericArray<Title> to_send (Library library, MediaType type) throws Error {
            var titles = new GenericArray<Title> ();
            for (uint i = 0; i < library.titles.get_n_items (); i++) {
                var t = (Title) library.titles.get_item (i);
                var unfinished = t.status == TitleStatus.PLAN_TO_WATCH || t.status == TitleStatus.WATCHING
                                 || t.status == TitleStatus.UP_TO_DATE;
                if (t.media_type == type && unfinished && !library.db.arr_seen (type, t.id)) {
                    titles.add (t);
                }
            }
            return titles;
        }
    }

    /**
     * Keeps the library in sync with Radarr or Sonarr: shortly after
     * startup, then periodically while the app runs. Settings keys start
     * with the service's name in lowercase; the API key and password live
     * in the keyring.
     */
    public abstract class ArrSync : Object {
        /* "Radarr" or "Sonarr" */
        public string service { get; construct; }
        /* What the service keeps */
        public MediaType media_type { get; construct; }

        private Settings settings;
        private Secret.Schema secret_schema;
        private uint timeout_id = 0;
        private HashTable<int64?, int64?> tvdb_cache = new HashTable<int64?, int64?> (int64_hash, int64_equal);

        public bool syncing { get; private set; }
        /* Message of the last failed sync, or null if it succeeded */
        public string? last_error { get; private set; }

        public signal void finished (ArrSyncResult result);

        construct {
            settings = new Settings (Config.APPLICATION_ID);
            settings.changed[key ("enabled")].connect (reschedule);
            settings.changed[key ("sync-interval")].connect (reschedule);
            secret_schema = new Secret.Schema ("io.github.jonnsl.Pipoca." + service, Secret.SchemaFlags.NONE,
                                               "account", Secret.SchemaAttributeType.STRING);
        }

        /* The settings key for @name, e.g. "radarr-enabled" */
        public string key (string name) {
            return "%s-%s".printf (service.down (), name);
        }

        /* @account is "api-key" or "password" */
        public async string? get_secret (string account) throws Error {
            return yield Secret.password_lookup (secret_schema, null, "account", account);
        }

        public async void set_secret (string account, string secret) throws Error {
            if (secret == "") {
                yield Secret.password_clear (secret_schema, null, "account", account);
                return;
            }
            // Translators: keyring labels, e.g. "Pipoca Radarr API key"
            var label = account == "api-key" ? _("Pipoca %s API key").printf (service)
                                             : _("Pipoca %s password").printf (service);
            yield Secret.password_store (secret_schema, Secret.COLLECTION_DEFAULT, label, secret, null,
                                         "account", account);
        }

        public int64 last_sync {
            get { return settings.get_int64 (key ("last-sync")); }
        }

        protected abstract ArrClient create_client (string address, string? api_key, string? username,
                                                    string? password, bool accept_any_certificate) throws Error;

        public async ArrClient make_client () throws Error {
            return create_client (settings.get_string (key ("address")), yield get_secret ("api-key"),
                                  settings.get_string (key ("username")), yield get_secret ("password"),
                                  settings.get_boolean (key ("accept-any-certificate")));
        }

        /* Adds @title to the service */
        protected abstract async void add (ArrClient client, Library library, Title title, int64 profile,
                                           string folder, Cancellable? cancellable) throws Error;

        /* Runs at the end of every sync, with the service's library */
        protected virtual async void finish (ArrClient client, Library library, GenericArray<ArrItem> items,
                                             Cancellable? cancellable) throws Error {
        }

        /* Starts periodic syncing; call once at startup */
        public void start () {
            reschedule ();
            if (!settings.get_boolean (key ("enabled"))) {
                return;
            }
            var interval = settings.get_int (key ("sync-interval")) * 60;
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
            if (!settings.get_boolean (key ("enabled"))) {
                return;
            }
            var minutes = settings.get_int (key ("sync-interval"));
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
                    warning ("%s sync failed: %s", service, e.message);
                }
            });
        }

        public async ArrSyncResult sync (Cancellable? cancellable = null) throws Error {
            if (syncing) {
                throw new IOError.PENDING (_("A sync is already running"));
            }
            syncing = true;
            try {
                var client = yield make_client ();
                var items = yield client.get_items (cancellable);
                var library = Library.get_default ();
                foreach (var item in items) {
                    yield resolve (library.tmdb, item, cancellable);
                }
                var result = ArrImport.apply (library, media_type, items);
                if (!settings.get_boolean (key ("read-only"))) {
                    result = yield send (client, library, result, cancellable);
                }
                yield finish (client, library, items, cancellable);

                settings.set_int64 (key ("last-sync"), new DateTime.now_utc ().to_unix ());
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

        /* Fills in the TMDB id from the TVDB id when the service doesn't have it */
        private async void resolve (TmdbClient tmdb, ArrItem item, Cancellable? cancellable) {
            if (item.tmdb_id > 0 || item.tvdb_id <= 0) {
                return;
            }
            var cached = tvdb_cache[item.tvdb_id];
            if (cached != null) {
                item.tmdb_id = cached;
                return;
            }
            try {
                item.tmdb_id = yield tmdb.find_by_external_id ("tvdb_id", item.tvdb_id.to_string (), media_type,
                                                               cancellable);
                tvdb_cache[item.tvdb_id] = item.tmdb_id;
            } catch (Error e) {
                debug ("Can't look up TVDB id %lld: %s", item.tvdb_id, e.message);
            }
        }

        /* Adds the unfinished titles the service never had, to the chosen profile and folder */
        private async ArrSyncResult send (ArrClient client, Library library, ArrSyncResult result,
                                          Cancellable? cancellable) throws Error {
            var titles = ArrImport.to_send (library, media_type);
            if (titles.length == 0) {
                return result;
            }

            // The service's first ones unless the user picked others it still has
            var profiles = yield client.get_quality_profiles (cancellable);
            if (profiles.length == 0) {
                throw new ArrError.NOT_CONFIGURED (_("%s has no quality profiles").printf (service));
            }
            var profile = profiles[0].id;
            var wanted_profile = settings.get_int64 (key ("quality-profile"));
            foreach (var p in profiles) {
                if (p.id == wanted_profile) {
                    profile = wanted_profile;
                }
            }
            var folders = yield client.get_root_folders (cancellable);
            if (folders.length == 0) {
                throw new ArrError.NOT_CONFIGURED (_("%s has no root folders").printf (service));
            }
            var wanted_folder = settings.get_string (key ("root-folder"));
            var folder = wanted_folder in folders ? wanted_folder : folders[0];

            foreach (var t in titles) {
                try {
                    yield add (client, library, t, profile, folder, cancellable);
                    library.db.mark_arr_seen (media_type, t.id);
                    result.titles_sent++;
                } catch (IOError.CANCELLED e) {
                    throw e;
                } catch (Error e) {
                    warning ("Can't add %s to %s: %s", t.key, service, e.message);
                    result.titles_failed++;
                }
            }
            return result;
        }
    }
}
