namespace Pipoca {
    public class Application : Adw.Application {
        /* Seconds between checks for stale titles; each title is refreshed at most once a day */
        private const uint REFRESH_INTERVAL = 60 * 60;

        private Settings settings;
        private bool services_started;
        /* Started at login with --background */
        private bool start_hidden;
        private bool held;

        public Application () {
            Object (
                application_id: Config.APPLICATION_ID,
                resource_base_path: Config.RESOURCE_PATH,
                flags: ApplicationFlags.DEFAULT_FLAGS
            );
        }

        construct {
            ActionEntry[] action_entries = {
                { "about", on_about_action },
                { "preferences", on_preferences_action },
                { "quit", quit },
                { "show-title", on_show_title, "s" },
            };
            add_action_entries (action_entries, this);
            set_accels_for_action ("app.quit", { "<primary>q" });
            set_accels_for_action ("app.preferences", { "<primary>comma" });
            set_accels_for_action ("win.search", { "<primary>n" });
            set_accels_for_action ("win.filter", { "<primary>f" });
            set_accels_for_action ("win.refresh", { "F5", "<primary>r" });
            set_accels_for_action ("win.view::watchlist", { "<primary>1" });
            set_accels_for_action ("win.view::upcoming", { "<primary>2" });
            set_accels_for_action ("win.view::discover", { "<primary>3" });
            set_accels_for_action ("win.view::watched", { "<primary>4" });
            set_accels_for_action ("win.view::dropped", { "<primary>5" });

            settings = new Settings (Config.APPLICATION_ID);
            add_main_option ("background", 0, OptionFlags.NONE, OptionArg.NONE,
                             _("Start without a window and keep checking for new releases"), null);
        }

        public override int handle_local_options (VariantDict options) {
            if (!options.contains ("background")) {
                return -1;
            }
            try {
                register ();
            } catch (Error e) {
                warning ("Can't register the application: %s", e.message);
                return 1;
            }
            // Already running, so there's nothing to start
            if (get_is_remote ()) {
                return 0;
            }
            start_hidden = true;
            return -1;
        }

        public override void startup () {
            base.startup ();
            // Custom widgets used in templates must be registered before the templates load
            typeof (ArrPreferencesGroup).ensure ();
            typeof (LibraryView).ensure ();
            typeof (Poster).ensure ();
            typeof (PosterCard).ensure ();
            typeof (UpcomingView).ensure ();
            typeof (DiscoverView).ensure ();

            settings.changed["run-in-background"].connect (update_hold);
            update_hold ();
        }

        public override void activate () {
            base.activate ();
            if (start_hidden) {
                start_hidden = false;
                // Without the setting, nothing holds the app and it quits right away
                if (settings.get_boolean ("run-in-background")) {
                    start_services ();
                }
                return;
            }
            if (active_window == null) {
                new Pipoca.Window (this);
                start_session ();
            }
            active_window.present ();
            start_services ();
        }

        /* Keeps running with no window while "Run in Background" is on */
        private void update_hold () {
            var wanted = settings.get_boolean ("run-in-background");
            if (wanted == held) {
                return;
            }
            held = wanted;
            if (held) {
                hold ();
                Background.set_status.begin (_("Checking for new episodes and releases"));
            } else {
                release ();
            }
        }

        private void start_services () {
            if (services_started) {
                return;
            }
            services_started = true;
            schedule_refresh ();
            KodiSync.get_default ().start ();
            RadarrSync.get_default ().start ();
            SonarrSync.get_default ().start ();
            Notifier.get_default ().start ();
        }

        /* What came out since the app was last opened is new */
        private void start_session () {
            var today = Utils.today ();
            var last = settings.get_string ("last-opened");
            Library.get_default ().new_since = last != "" ? last : today;
            settings.set_string ("last-opened", today);
        }

        private void schedule_refresh () {
            // Let the window show up first
            Timeout.add_seconds (2, () => {
                refresh_library ();
                return Source.REMOVE;
            });
            // Titles go stale while the app stays open, e.g. in the background
            Timeout.add_seconds (REFRESH_INTERVAL, () => {
                refresh_library ();
                return Source.CONTINUE;
            });
        }

        private void refresh_library () {
            if (settings.get_boolean ("refresh-automatically") && NetworkMonitor.get_default ().network_available) {
                Library.get_default ().refresh_library.begin (false);
            }
        }

        /* Opens a title by key ("tv:1399"), e.g. from a notification */
        private void on_show_title (SimpleAction action, Variant? param) {
            MediaType type;
            int64 id;
            if (!Title.try_parse_key (param.get_string (), out type, out id)) {
                return;
            }
            var t = Library.get_default ().lookup (type, id);
            if (t == null) {
                return;
            }
            activate ();
            var win = active_window as Window;
            if (win != null) {
                win.show_title (t);
            }
        }

        private void on_about_action () {
            var about = new Adw.AboutDialog () {
                application_name = _("Pipoca"),
                application_icon = Config.APPLICATION_ID,
                developer_name = "Jonnathan Soares",
                version = Config.VERSION,
                developers = { "Jonnathan Soares" },
                // Translators: Replace "translator-credits" with your name/username, and optionally an email or URL.
                translator_credits = _("translator-credits"),
                copyright = "© 2026 Jonnathan Soares",
                license_type = Gtk.License.GPL_3_0,
                comments = _("This product uses the TMDB API but is not endorsed or certified by TMDB."),
            };
            about.add_link (_("The Movie Database (TMDB)"), "https://www.themoviedb.org/");
            about.present (active_window);
        }

        private void on_preferences_action () {
            new PreferencesDialog ().present (active_window);
        }
    }
}
