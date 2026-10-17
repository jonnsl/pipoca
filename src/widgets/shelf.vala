namespace Aperture {
    /* One TMDB list on the Discover view */
    public class DiscoverList : Object {
        public string title;
        public string path;
        /* For lists of one media type, whose results don't say which */
        public MediaType? media_type;
        /* Whether release dates depend on the user's country */
        public bool regional;
        /* Leave out titles in the library, for suggestions */
        public bool exclude_library;

        public DiscoverList (string title, string path, MediaType? media_type, bool regional = false) {
            this.title = title;
            this.path = path;
            this.media_type = media_type;
            this.regional = regional;
        }

        public static DiscoverList[] get_all () {
            return {
                new DiscoverList (_("Trending This Week"), "/trending/all/week", null),
                new DiscoverList (_("Popular Movies"), "/movie/popular", MediaType.MOVIE),
                new DiscoverList (_("Popular Shows"), "/tv/popular", MediaType.TV),
                new DiscoverList (_("Now in Theaters"), "/movie/now_playing", MediaType.MOVIE, true),
                new DiscoverList (_("Upcoming Movies"), "/movie/upcoming", MediaType.MOVIE, true),
                new DiscoverList (_("Airing Today"), "/tv/airing_today", MediaType.TV),
            };
        }

        /* TMDB's recommendations based on @t */
        public static DiscoverList recommendations (string title, Title t) {
            return new DiscoverList (title, "/%s/%lld/recommendations".printf (t.media_type.to_api_string (), t.id),
                                     t.media_type);
        }

        /* A page of the list (from 1), as the library's canonical titles */
        public async GenericArray<Title> fetch (int page, Cancellable? cancellable, out int total_pages) throws Error {
            var library = Library.get_default ();
            var titles = yield library.tmdb.get_list (path, media_type, regional, page, cancellable, out total_pages);
            var result = new GenericArray<Title> ();
            foreach (var t in titles) {
                var canonical = library.intern (t);
                if (!exclude_library || !canonical.in_library) {
                    result.add (canonical);
                }
            }
            return result;
        }
    }

    /* A header and a horizontal row of posters from a DiscoverList */
    [GtkTemplate (ui = "/io/github/jonnsl/Aperture/widgets/shelf.ui")]
    public class Shelf : Gtk.Box {
        [GtkChild] private unowned Gtk.Label title_label;
        [GtkChild] private unowned Gtk.Button prev_button;
        [GtkChild] private unowned Gtk.Button next_button;
        [GtkChild] private unowned Gtk.Button see_all_button;
        [GtkChild] private unowned Gtk.Stack stack;
        [GtkChild] private unowned Gtk.Label error_label;
        [GtkChild] private unowned Gtk.ScrolledWindow scroller;
        [GtkChild] private unowned Gtk.Box cards_box;

        private Cancellable? cancellable;
        private Adw.TimedAnimation? scroll_animation;

        public DiscoverList list { get; construct; }
        /* Whether the last load found anything */
        public bool has_items { get; private set; }

        public signal void title_activated (Title title);
        public signal void see_all (DiscoverList list);

        public Shelf (DiscoverList list) {
            Object (list: list);
        }

        construct {
            title_label.label = list.title;
            update_relation (Gtk.AccessibleRelation.LABELLED_BY, title_label, null, -1);
            var adj = scroller.hadjustment;
            adj.value_changed.connect (update_buttons);
            adj.changed.connect (update_buttons);
            update_buttons ();
        }

        public override void dispose () {
            if (cancellable != null) {
                cancellable.cancel ();
            }
            dispose_template (typeof (Shelf));
            base.dispose ();
        }

        /* Loads the first page of the list; returns false if it failed */
        public async bool load () {
            if (cancellable != null) {
                cancellable.cancel ();
            }
            cancellable = new Cancellable ();
            var c = cancellable;
            if (cards_box.get_first_child () == null) {
                stack.visible_child_name = "loading";
            }
            try {
                int total_pages;
                var titles = yield list.fetch (1, c, out total_pages);
                Gtk.Widget? child;
                while ((child = cards_box.get_first_child ()) != null) {
                    cards_box.remove (child);
                }
                foreach (var t in titles) {
                    cards_box.append (make_card (t));
                }
                scroller.hadjustment.value = 0;
                see_all_button.sensitive = total_pages > 1;
                has_items = titles.length > 0;
                if (has_items) {
                    stack.visible_child_name = "content";
                } else {
                    error_label.label = _("Nothing to show yet");
                    stack.visible_child_name = "error";
                }
                return true;
            } catch (IOError.CANCELLED e) {
                return true;
            } catch (Error e) {
                warning ("Can't load %s: %s", list.path, e.message);
                // Keep what was loaded before, if anything
                if (cards_box.get_first_child () == null) {
                    error_label.label = _("Can’t load this list");
                    stack.visible_child_name = "error";
                }
                return false;
            }
        }

        private Gtk.Widget make_card (Title t) {
            var button = new Gtk.Button () {
                child = new PosterCard (t) { show_library_emblem = true },
                css_classes = { "flat", "poster-card" },
            };
            button.update_property (Gtk.AccessibleProperty.LABEL, t.name, -1);
            button.clicked.connect (() => title_activated (t));
            return button;
        }

        private void update_buttons () {
            var adj = scroller.hadjustment;
            prev_button.sensitive = adj.value > 0;
            next_button.sensitive = adj.value + adj.page_size < adj.upper - 1;
        }

        private void scroll_by (double pages) {
            var adj = scroller.hadjustment;
            var target = (adj.value + pages * adj.page_size * 0.9).clamp (adj.lower, adj.upper - adj.page_size);
            if (scroll_animation != null) {
                scroll_animation.skip ();
            }
            scroll_animation = new Adw.TimedAnimation (scroller, adj.value, target, 300,
                                                       new Adw.PropertyAnimationTarget (adj, "value"));
            scroll_animation.play ();
        }

        [GtkCallback]
        private void on_prev_clicked () {
            scroll_by (-1);
        }

        [GtkCallback]
        private void on_next_clicked () {
            scroll_by (1);
        }

        [GtkCallback]
        private void on_see_all_clicked () {
            see_all (list);
        }
    }
}
