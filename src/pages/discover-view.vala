namespace Aperture {
    /* Shelves of TMDB lists, loaded the first time the view is shown */
    [GtkTemplate (ui = "/io/github/jonnsl/Aperture/pages/discover-view.ui")]
    public class DiscoverView : Adw.Bin {
        /* Lists change slowly; reload when shown after this long */
        private const int64 MAX_AGE = TimeSpan.HOUR;
        /* How many recent titles suggestions are picked from */
        private const int SEED_CHOICES = 10;

        [GtkChild] private unowned Gtk.Stack stack;
        [GtkChild] private unowned Gtk.Box shelves_box;
        [GtkChild] private unowned Adw.StatusPage offline_page;

        private Shelf[] shelves = {};
        /* Suggestions based on the library, first; changes with each reload */
        private Shelf? for_you;
        private int64 loaded_at = 0;
        private NetworkMonitor monitor;

        public signal void title_activated (Title title);
        public signal void list_activated (DiscoverList list);

        construct {
            foreach (var list in DiscoverList.get_all ()) {
                var shelf = make_shelf (list);
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

        private Shelf make_shelf (DiscoverList list) {
            var shelf = new Shelf (list);
            shelf.title_activated.connect ((t) => title_activated (t));
            shelf.see_all.connect ((l) => list_activated (l));
            return shelf;
        }

        /* A random title among the ones most recently watched or added */
        private Title? pick_seed () {
            var candidates = new GenericArray<Title> ();
            var titles = Library.get_default ().titles;
            for (uint i = 0; i < titles.get_n_items (); i++) {
                var t = (Title) titles.get_item (i);
                if (!t.is_dropped) {
                    candidates.add (t);
                }
            }
            if (candidates.length == 0) {
                return null;
            }
            candidates.sort ((a, b) => {
                var x = int64.max (a.last_watched_at, a.added_at);
                var y = int64.max (b.last_watched_at, b.added_at);
                return x < y ? 1 : (x > y ? -1 : 0);
            });
            return candidates[Random.int_range (0, int.min (candidates.length, SEED_CHOICES))];
        }

        private void update_for_you () {
            if (for_you != null) {
                shelves_box.remove (for_you);
                for_you = null;
            }
            var seed = pick_seed ();
            if (seed == null) {
                return;
            }
            var heading = seed.last_watched_at > 0 ? _("Because You Watched %s") : _("Because You Added %s");
            var list = DiscoverList.recommendations (heading.printf (seed.name), seed);
            list.exclude_library = true;
            for_you = make_shelf (list);
            shelves_box.prepend (for_you);
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
            update_for_you ();
            Shelf[] all = shelves;
            if (for_you != null) {
                all += for_you;
            }
            var pending = all.length;
            var failures = 0;
            foreach (var shelf in all) {
                shelf.load.begin ((obj, res) => {
                    if (!shelf.load.end (res)) {
                        failures++;
                    } else if (shelf == for_you && !shelf.has_items) {
                        // Everything suggested is in the library already
                        shelf.visible = false;
                    }
                    // Nothing at all usually means no connection to TMDB
                    if (--pending == 0 && failures == all.length) {
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
