namespace Aperture {
    /**
     * Sends desktop notifications for new episodes and movie releases of
     * titles with "Notify Me" on. Each release is notified once. After a
     * break, releases from up to a week back are caught up on.
     */
    public class Notifier : Object {
        private const int MAX_CATCH_UP_DAYS = 7;
        private const uint CHECK_INTERVAL = 30 * 60;

        private static Notifier? instance;

        private Settings settings;
        private Library library;
        private bool started;

        public static Notifier get_default () {
            if (instance == null) {
                instance = new Notifier ();
            }
            return instance;
        }

        construct {
            settings = new Settings (Config.APPLICATION_ID);
            library = Library.get_default ();
        }

        /* Checks after each library refresh and every half hour; call once at startup */
        public void start () {
            if (started) {
                return;
            }
            started = true;
            library.notify["refreshing-library"].connect (() => {
                if (!library.refreshing_library) {
                    check ();
                }
            });
            Timeout.add_seconds (CHECK_INTERVAL, () => {
                check_unless_refreshing ();
                return Source.CONTINUE;
            });
            // The startup refresh may bring new episodes; if it's running, it checks when done
            Timeout.add_seconds (10, () => {
                check_unless_refreshing ();
                return Source.REMOVE;
            });
        }

        private void check_unless_refreshing () {
            if (!library.refreshing_library) {
                check ();
            }
        }

        /**
         * Returns the releases to notify about now and records them as
         * notified. Releases from before the first check are never notified,
         * so turning notifications on doesn't bring a flood of old ones.
         */
        public GenericArray<Release> take_pending () {
            var today = Utils.today ();
            var earliest = Utils.days_from_today (-MAX_CATCH_UP_DAYS);
            var last = settings.get_string ("notified-until");
            var from = last == "" ? today : (last < earliest ? earliest : last);
            settings.set_string ("notified-until", today);

            var episodes = settings.get_boolean ("notify-new-episodes");
            var movies = settings.get_boolean ("notify-movie-releases");
            var result = new GenericArray<Release> ();
            foreach (var r in library.get_releases (from, today)) {
                if (!r.title.notify_enabled) {
                    continue;
                }
                if (r.episode != null ? (!episodes || r.episode.watched) : !movies) {
                    continue;
                }
                var season = r.episode != null ? r.episode.season_number : -1;
                var number = r.episode != null ? r.episode.episode_number : -1;
                try {
                    if (library.db.mark_notified (r.title.media_type, r.title.id, season, number)) {
                        result.add (r);
                    }
                } catch (Error e) {
                    warning ("Can't record notification: %s", e.message);
                }
            }
            return result;
        }

        public void check () {
            var app = GLib.Application.get_default ();
            if (app == null) {
                return;
            }
            // One notification per title
            var keys = new GenericArray<string> ();
            var by_title = new HashTable<string, GenericArray<Release>> (str_hash, str_equal);
            foreach (var r in take_pending ()) {
                var list = by_title[r.title.key];
                if (list == null) {
                    list = new GenericArray<Release> ();
                    by_title[r.title.key] = list;
                    keys.add (r.title.key);
                }
                list.add (r);
            }
            foreach (var key in keys) {
                send (app, by_title[key]);
            }
        }

        private void send (GLib.Application app, GenericArray<Release> releases) {
            var t = releases[0].title;
            string body;
            if (t.is_movie) {
                body = releases[0].date == Utils.today ()
                    ? _("Released today")
                    : _("Released on %s").printf (Utils.format_date (releases[0].date));
            } else if (releases.length == 1) {
                body = _("New episode: %s").printf (releases[0].episode.describe ());
            } else {
                body = ngettext ("%d new episode", "%d new episodes", releases.length).printf (releases.length);
            }
            var n = new Notification (t.name);
            n.set_body (body);
            if (t.poster_path != null) {
                var poster = ImageCache.get_default ().get_cached_file (t.poster_path, "w342");
                if (poster != null) {
                    n.set_icon (new FileIcon (poster));
                }
            }
            n.set_default_action_and_target_value ("app.show-title", new Variant.string (t.key));
            // Replaces an earlier notification for the same title
            app.send_notification ("release-" + t.key, n);
        }
    }
}
