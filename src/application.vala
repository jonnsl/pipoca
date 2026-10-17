namespace Aperture {
    public class Application : Adw.Application {
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
            };
            add_action_entries (action_entries, this);
            set_accels_for_action ("app.quit", { "<primary>q" });
            set_accels_for_action ("app.preferences", { "<primary>comma" });
            set_accels_for_action ("win.search", { "<primary>n" });
            set_accels_for_action ("win.filter", { "<primary>f" });
            set_accels_for_action ("win.refresh", { "F5", "<primary>r" });
            set_accels_for_action ("win.view::watchlist", { "<primary>1" });
            set_accels_for_action ("win.view::upcoming", { "<primary>2" });
            set_accels_for_action ("win.view::watched", { "<primary>3" });
            set_accels_for_action ("win.view::dropped", { "<primary>4" });
        }

        public override void startup () {
            base.startup ();
            // Custom widgets used in templates must be registered before the templates load
            typeof (LibraryView).ensure ();
            typeof (Poster).ensure ();
            typeof (PosterCard).ensure ();
            typeof (UpcomingView).ensure ();
        }

        public override void activate () {
            base.activate ();
            var first = active_window == null;
            var win = active_window ?? new Aperture.Window (this);
            win.present ();
            if (first) {
                start_session ();
                schedule_refresh ();
                KodiSync.get_default ().start ();
            }
        }

        /* What came out since the app was last opened is new */
        private void start_session () {
            var settings = new Settings (Config.APPLICATION_ID);
            var today = Utils.today ();
            var last = settings.get_string ("last-opened");
            Library.get_default ().new_since = last != "" ? last : today;
            settings.set_string ("last-opened", today);
        }

        private void schedule_refresh () {
            var settings = new Settings (Config.APPLICATION_ID);
            if (!settings.get_boolean ("refresh-automatically")) {
                return;
            }
            // Let the window show up first
            Timeout.add_seconds (2, () => {
                if (NetworkMonitor.get_default ().network_available) {
                    Library.get_default ().refresh_library.begin (false);
                }
                return Source.REMOVE;
            });
        }

        private void on_about_action () {
            var about = new Adw.AboutDialog () {
                application_name = _("Aperture"),
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
