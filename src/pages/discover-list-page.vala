namespace Pipoca {
    /* A whole TMDB list as a grid, loading more pages as it scrolls */
    [GtkTemplate (ui = "/io/github/jonnsl/Pipoca/pages/discover-list-page.ui")]
    public class DiscoverListPage : Adw.NavigationPage {
        /* Start loading the next page this far (px) from the end */
        private const double PRELOAD_DISTANCE = 800;

        [GtkChild] private unowned Gtk.Stack stack;
        [GtkChild] private unowned Adw.StatusPage error_page;
        [GtkChild] private unowned Gtk.ScrolledWindow scroller;
        [GtkChild] private unowned Gtk.FlowBox grid;
        [GtkChild] private unowned Adw.Spinner more_spinner;

        private Cancellable cancellable = new Cancellable ();
        private int next_page = 1;
        private int total_pages = 1;
        private bool loading;
        /* Pages can overlap when the list changes while scrolling */
        private GenericSet<string> shown_keys = new GenericSet<string> (str_hash, str_equal);

        public DiscoverList list { get; construct; }

        public DiscoverListPage (DiscoverList list) {
            Object (list: list, title: list.title);
        }

        construct {
            var adj = scroller.vadjustment;
            adj.value_changed.connect (maybe_load_more);
            adj.changed.connect (maybe_load_more);
            load_more.begin ();
        }

        public override void dispose () {
            cancellable.cancel ();
            dispose_template (typeof (DiscoverListPage));
            base.dispose ();
        }

        private void maybe_load_more () {
            var adj = scroller.vadjustment;
            // Not laid out yet; the adjustment changes once it is
            if (adj.page_size <= 0) {
                return;
            }
            if (adj.value + adj.page_size >= adj.upper - PRELOAD_DISTANCE) {
                load_more.begin ();
            }
        }

        private async void load_more () {
            if (loading || next_page > total_pages || stack.visible_child_name == "error") {
                return;
            }
            loading = true;
            var first = next_page == 1;
            more_spinner.visible = !first;
            try {
                int pages;
                var titles = yield list.fetch (next_page, cancellable, out pages);
                total_pages = int.max (pages, 1);
                next_page++;
                var added = 0;
                foreach (var t in titles) {
                    if (t.key in shown_keys) {
                        continue;
                    }
                    shown_keys.add (t.key);
                    added++;
                    grid.append (new Gtk.FlowBoxChild () {
                        child = new PosterCard (t) { show_library_emblem = true },
                        css_classes = { "poster-card" },
                    });
                }
                stack.visible_child_name = "content";
                loading = false;
                more_spinner.visible = false;
                // New cards change the adjustment once laid out, which checks again.
                // A page with nothing new doesn't, so check now.
                if (added == 0) {
                    maybe_load_more ();
                }
                return;
            } catch (IOError.CANCELLED e) {
                return;
            } catch (Error e) {
                warning ("Can't load %s page %d: %s", list.path, next_page, e.message);
                more_spinner.visible = false;
                if (first) {
                    loading = false;
                    error_page.description = e.message;
                    stack.visible_child_name = "error";
                } else {
                    var win = Window.of (this);
                    if (win != null) {
                        win.add_toast (new Adw.Toast (_("Can’t load more titles")));
                    }
                    // Don't retry on every scroll; reaching the end again after a while will
                    Timeout.add_seconds (10, () => {
                        loading = false;
                        return Source.REMOVE;
                    });
                }
            }
        }

        [GtkCallback]
        private void on_retry_clicked () {
            stack.visible_child_name = "loading";
            loading = false;
            load_more.begin ();
        }

        [GtkCallback]
        private void on_child_activated (Gtk.FlowBoxChild child) {
            var win = Window.of (this);
            if (win != null) {
                win.show_title (((PosterCard) child.child).title);
            }
        }
    }
}
