namespace Aperture {
    [GtkTemplate (ui = "/io/github/jonnsl/Aperture/window.ui")]
    public class Window : Adw.ApplicationWindow {
        [GtkChild] private unowned Adw.ToastOverlay toast_overlay;
        [GtkChild] private unowned Adw.NavigationView navigation_view;
        [GtkChild] private unowned Gtk.ToggleButton search_button;
        [GtkChild] private unowned Gtk.SearchBar search_bar;
        [GtkChild] private unowned Gtk.SearchEntry library_search;
        [GtkChild] private unowned Adw.Banner offline_banner;
        [GtkChild] private unowned Gtk.Box filter_bar;
        [GtkChild] private unowned Adw.ToggleGroup media_filter;
        [GtkChild] private unowned Gtk.MenuButton show_status_button;
        [GtkChild] private unowned Gtk.MenuButton sort_button;
        [GtkChild] private unowned Adw.ViewStack view_stack;
        [GtkChild] private unowned LibraryView watchlist_view;
        [GtkChild] private unowned UpcomingView upcoming_view;
        [GtkChild] private unowned DiscoverView discover_view;
        [GtkChild] private unowned LibraryView watched_view;
        [GtkChild] private unowned LibraryView dropped_view;

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
            var show_status = new SimpleAction.stateful ("show-status", VariantType.STRING, new Variant.string (""));
            show_status.change_state.connect ((action, value) => {
                action.set_state (value);
                update_show_status ();
            });
            add_action (show_status);

            watchlist_view.setup (LibraryKind.WATCHLIST);
            watched_view.setup (LibraryKind.WATCHED);
            dropped_view.setup (LibraryKind.DROPPED);
            foreach (var view in new LibraryView[] { watchlist_view, watched_view, dropped_view }) {
                media_filter.bind_property ("active-name", view, "media-filter", BindingFlags.SYNC_CREATE);
                library_search.bind_property ("text", view, "search-text", BindingFlags.SYNC_CREATE);
                settings.bind ("sort-order", view, "sort-order", SettingsBindFlags.GET);
                view.title_activated.connect (show_title);
            }
            media_filter.bind_property ("active-name", upcoming_view, "media-filter", BindingFlags.SYNC_CREATE);
            library_search.bind_property ("text", upcoming_view, "search-text", BindingFlags.SYNC_CREATE);
            upcoming_view.title_activated.connect (show_title);
            discover_view.title_activated.connect (show_title);
            discover_view.list_activated.connect ((list) => navigation_view.push (new DiscoverListPage (list)));

            // Show status only means something for finished shows
            view_stack.notify["visible-child-name"].connect (update_show_status);
            media_filter.notify["active-name"].connect (update_show_status);
            update_show_status ();

            search_bar.connect_entry (library_search);
            search_bar.notify["search-mode-enabled"].connect (() => {
                if (!search_bar.search_mode_enabled) {
                    library_search.text = "";
                }
            });
            view_stack.notify["visible-child-name"].connect (update_library_filter);
            navigation_view.notify["visible-page"].connect (update_library_filter);
            update_library_filter ();

            var monitor = NetworkMonitor.get_default ();
            monitor.bind_property ("network-available", offline_banner, "revealed",
                                   BindingFlags.SYNC_CREATE | BindingFlags.INVERT_BOOLEAN);
        }

        /* The library filters and search only apply to library views on the main page */
        private void update_library_filter () {
            var library_view = view_stack.visible_child_name != "discover";
            filter_bar.visible = library_view;
            search_button.visible = library_view;
            if (!library_view) {
                search_bar.search_mode_enabled = false;
            }
            // Typing filters the library
            var on_main = navigation_view.visible_page.tag == "main";
            search_bar.key_capture_widget = on_main && library_view ? this : null;
        }

        private void update_show_status () {
            var status = get_action_state ("show-status").get_string ();
            var label = status == "" ? _("All Statuses") : Utils.tmdb_status_label (status);
            show_status_button.label = label;
            show_status_button.update_property (Gtk.AccessibleProperty.LABEL,
                                                _("Show status: %s").printf (label), -1);
            show_status_button.visible = view_stack.visible_child_name == "watched";
            // Upcoming is always by date
            sort_button.visible = view_stack.visible_child_name != "upcoming";
            show_status_button.sensitive = media_filter.active_name != "movie";
            // Movies have no show status, so the filter is off while only movies are listed
            watched_view.show_status = show_status_button.sensitive ? status : "";
        }

        public static Window? of (Gtk.Widget widget) {
            return widget.get_root () as Window;
        }

        public void add_toast (Adw.Toast toast) {
            toast_overlay.add_toast (toast);
        }

        public void show_title (Title title) {
            var library = Library.get_default ();
            var t = library.intern (title);
            library.mark_seen (t);
            var current = navigation_view.visible_page as DetailsPage;
            if (current != null && current.title_object == t) {
                return;
            }
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
            // Discover isn't the library; filter the watchlist instead
            if (view_stack.visible_child_name == "discover") {
                view_stack.visible_child_name = "watchlist";
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
            if (navigation_view.visible_page.tag == "main" && view_stack.visible_child_name == "discover") {
                discover_view.reload ();
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
