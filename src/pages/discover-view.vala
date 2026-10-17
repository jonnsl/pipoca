namespace Aperture {
    /* Shelves of TMDB lists, loaded the first time the view is shown */
    [GtkTemplate (ui = "/io/github/jonnsl/Aperture/pages/discover-view.ui")]
    public class DiscoverView : Adw.Bin {
        /* Lists change slowly; reload when shown after this long */
        private const int64 MAX_AGE = TimeSpan.HOUR;

        [GtkChild] private unowned Gtk.Stack stack;
        [GtkChild] private unowned Gtk.Box shelves_box;
        [GtkChild] private unowned Adw.StatusPage offline_page;

        private Shelf[] shelves = {};
        private int64 loaded_at = 0;
        private NetworkMonitor monitor;

        public signal void title_activated (Title title);
        public signal void list_activated (DiscoverList list);

        construct {
            foreach (var list in DiscoverList.get_all ()) {
                var shelf = new Shelf (list);
                shelf.title_activated.connect ((t) => title_activated (t));
                shelf.see_all.connect ((l) => list_activated (l));
                shelves_box.append (shelf);
                shelves += shelf;
            }
            map.connect (() => {
                if (loaded_at == 0 || get_monotonic_time () - loaded_at > MAX_AGE) {
                    reload ();
                }
            });
            monitor = NetworkMonitor.get_default ();
            monitor.notify["network-available"].connect (on_network_changed);
        }

        public override void dispose () {
            monitor.notify["network-available"].disconnect (on_network_changed);
            dispose_template (typeof (DiscoverView));
            base.dispose ();
        }

        private void on_network_changed () {
            // Back online: load what couldn't be loaded
            if (monitor.network_available && stack.visible_child_name == "offline" && get_mapped ()) {
                reload ();
            }
        }

        public void reload () {
            if (!monitor.network_available) {
                show_offline (null);
                return;
            }
            loaded_at = get_monotonic_time ();
            stack.visible_child_name = "content";
            var pending = shelves.length;
            var failures = 0;
            foreach (var shelf in shelves) {
                shelf.load.begin ((obj, res) => {
                    if (!shelf.load.end (res)) {
                        failures++;
                    }
                    // Nothing at all usually means no connection to TMDB
                    if (--pending == 0 && failures == shelves.length) {
                        show_offline (_("Can’t reach TMDB right now"));
                    }
                });
            }
        }

        private void show_offline (string? description) {
            loaded_at = 0;
            offline_page.description = description ?? _("Connect to the internet to discover movies and shows");
            stack.visible_child_name = "offline";
        }

        [GtkCallback]
        private void on_retry_clicked () {
            reload ();
        }
    }
}
