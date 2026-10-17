namespace Aperture {
    [GtkTemplate (ui = "/io/github/jonnsl/Aperture/window.ui")]
    public class Window : Adw.ApplicationWindow {
        [GtkChild] private unowned Adw.ToastOverlay toast_overlay;
        [GtkChild] private unowned Adw.NavigationView navigation_view;
        [GtkChild] private unowned Gtk.SearchBar search_bar;
        [GtkChild] private unowned Gtk.SearchEntry library_search;
        [GtkChild] private unowned Adw.Banner offline_banner;
        [GtkChild] private unowned Adw.ToggleGroup media_filter;
        [GtkChild] private unowned Adw.ViewStack view_stack;
        [GtkChild] private unowned LibraryView watchlist_view;
        [GtkChild] private unowned LibraryView watched_view;

        private Settings settings;

        public Window (Gtk.Application app) {
            Object (application: app);
        }

        construct {
            if (Config.PROFILE == "development") {
                add_css_class ("devel");
            }

            settings = new Settings (Config.APPLICATION_ID);
            settings.bind ("window-width", this, "default-width", SettingsBindFlags.DEFAULT);
            settings.bind ("window-height", this, "default-height", SettingsBindFlags.DEFAULT);
            settings.bind ("window-maximized", this, "maximized", SettingsBindFlags.DEFAULT);

            ActionEntry[] entries = {
                { "search", on_search },
                { "filter", on_filter },
                { "refresh", on_refresh },
                { "view", on_view, "s" },
            };
            add_action_entries (entries, this);
            add_action (settings.create_action ("sort-order"));

            watchlist_view.setup (LibraryKind.WATCHLIST);
            watched_view.setup (LibraryKind.WATCHED);
            foreach (var view in new LibraryView[] { watchlist_view, watched_view }) {
                media_filter.bind_property ("active-name", view, "media-filter", BindingFlags.SYNC_CREATE);
                library_search.bind_property ("text", view, "search-text", BindingFlags.SYNC_CREATE);
                settings.bind ("sort-order", view, "sort-order", SettingsBindFlags.GET);
                view.title_activated.connect (show_title);
            }

            search_bar.connect_entry (library_search);
            search_bar.key_capture_widget = this;
            search_bar.notify["search-mode-enabled"].connect (() => {
                if (!search_bar.search_mode_enabled) {
                    library_search.text = "";
                }
            });
            // Typing should only filter the library from the main page
            navigation_view.notify["visible-page"].connect (() => {
                search_bar.key_capture_widget = navigation_view.visible_page.tag == "main" ? this : null;
            });

            var monitor = NetworkMonitor.get_default ();
            monitor.bind_property ("network-available", offline_banner, "revealed",
                                   BindingFlags.SYNC_CREATE | BindingFlags.INVERT_BOOLEAN);
        }

        public static Window? of (Gtk.Widget widget) {
            return widget.get_root () as Window;
        }

        public void add_toast (Adw.Toast toast) {
            toast_overlay.add_toast (toast);
        }

        public void show_title (Title title) {
            var t = Library.get_default ().intern (title);
            navigation_view.push (new DetailsPage (t));
        }

        private void on_search () {
            var dialog = new SearchDialog ();
            dialog.title_activated.connect ((t) => {
                dialog.close ();
                // Leave any details page open so the new one lands on top of the main page
                navigation_view.pop_to_tag ("main");
                show_title (t);
            });
            dialog.present (this);
        }

        private void on_filter () {
            if (navigation_view.visible_page.tag != "main") {
                navigation_view.pop_to_tag ("main");
            }
            search_bar.search_mode_enabled = true;
            library_search.grab_focus ();
        }

        private void on_refresh () {
            var details = navigation_view.visible_page as DetailsPage;
            if (details != null) {
                details.refresh ();
                return;
            }
            Library.get_default ().refresh_library.begin (true);
        }

        private void on_view (SimpleAction action, Variant? param) {
            navigation_view.pop_to_tag ("main");
            view_stack.visible_child_name = param.get_string ();
        }
    }
}
