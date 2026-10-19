namespace Pipoca {
    /**
     * Syncs shows with Sonarr; see ArrImport for the rules. A show added to
     * Sonarr has every episode monitored except the ones already watched
     * here. Sonarr only knows a new show's episodes once it has fetched it,
     * and resets their monitoring when it's done, so until then the show
     * stays pending and later syncs try again.
     */
    public class SonarrSync : ArrSync {
        /* How long to wait for Sonarr to fetch a show it was just given */
        private const int EPISODE_WAIT_SECONDS = 30;
        private const int EPISODE_POLL_SECONDS = 2;

        private static SonarrSync? instance;

        private SonarrSync () {
            Object (service: "Sonarr", media_type: MediaType.TV);
        }

        public static SonarrSync get_default () {
            if (instance == null) {
                instance = new SonarrSync ();
            }
            return instance;
        }

        protected override ArrClient create_client (string address, string? api_key, string? username,
                                                    string? password, bool accept_any_certificate) throws Error {
            return new SonarrClient (address, api_key, username, password, accept_any_certificate);
        }

        protected override async void add (ArrClient client, Library library, Title title, int64 profile,
                                           string folder, Cancellable? cancellable) throws Error {
            var sonarr = (SonarrClient) client;
            var series_id = yield sonarr.add_series (title.id, profile, folder, cancellable);
            if (library.db.load_watch_events (MediaType.TV, title.id).length == 0) {
                return;
            }
            // It's in Sonarr now, so this can't fail the add; it's retried next sync
            library.db.set_sonarr_pending (title.id, series_id);
            try {
                for (var waited = 0; waited < EPISODE_WAIT_SECONDS; waited += EPISODE_POLL_SECONDS) {
                    if (yield unmonitor_watched (sonarr, library, title.id, series_id, cancellable)) {
                        return;
                    }
                    yield wait (EPISODE_POLL_SECONDS);
                }
            } catch (IOError.CANCELLED e) {
                throw e;
            } catch (Error e) {
                warning ("Can't unmonitor watched episodes of %s in Sonarr: %s", title.key, e.message);
            }
        }

        protected override async void finish (ArrClient client, Library library, GenericArray<ArrItem> items,
                                              Cancellable? cancellable) throws Error {
            var pending = library.db.load_sonarr_pending ();
            if (pending.length == 0) {
                return;
            }
            var in_sonarr = new GenericSet<int64?> (int64_hash, int64_equal);
            foreach (var item in items) {
                in_sonarr.add (item.arr_id);
            }
            for (var i = 0; i + 1 < pending.length; i += 2) {
                var tmdb_id = pending[i];
                var series_id = pending[i + 1];
                // Removed from Sonarr in the meantime
                if (!(series_id in in_sonarr)) {
                    library.db.clear_sonarr_pending (tmdb_id);
                    continue;
                }
                try {
                    yield unmonitor_watched ((SonarrClient) client, library, tmdb_id, series_id, cancellable);
                } catch (IOError.CANCELLED e) {
                    throw e;
                } catch (Error e) {
                    warning ("Can't unmonitor watched episodes of tv/%lld in Sonarr: %s", tmdb_id, e.message);
                }
            }
        }

        /* Returns false if Sonarr isn't done fetching the series yet */
        private async bool unmonitor_watched (SonarrClient sonarr, Library library, int64 tmdb_id, int64 series_id,
                                              Cancellable? cancellable) throws Error {
            if (yield sonarr.refreshing (series_id, cancellable)) {
                return false;
            }
            var episodes = yield sonarr.get_episodes (series_id, cancellable);
            if (episodes.length == 0) {
                return false;
            }
            var watched = new GenericSet<string> (str_hash, str_equal);
            foreach (var e in library.db.load_watch_events (MediaType.TV, tmdb_id)) {
                watched.add ("%d:%d".printf (e.season_number, e.episode_number));
            }
            int64[] ids = {};
            foreach (var e in episodes) {
                if (e.monitored && "%d:%d".printf (e.season, e.episode) in watched) {
                    ids += e.id;
                }
            }
            if (ids.length > 0) {
                yield sonarr.set_monitored (ids, false, cancellable);
            }
            library.db.clear_sonarr_pending (tmdb_id);
            return true;
        }

        private async void wait (int seconds) {
            Timeout.add_seconds (seconds, wait.callback);
            yield;
        }
    }
}
