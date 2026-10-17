namespace Aperture {
    public enum LibraryKind {
        WATCHLIST,
        WATCHED,
        DROPPED,
    }

    /* A grid of library titles, split into sections, with empty states */
    [GtkTemplate (ui = "/io/github/jonnsl/Aperture/pages/library-view.ui")]
    public class LibraryView : Adw.Bin {
        [GtkChild] private unowned Gtk.Stack stack;
        [GtkChild] private unowned Gtk.Box sections_box;
        [GtkChild] private unowned Adw.StatusPage empty_page;

        private class Section {
            public Gtk.Widget header;
            public Gtk.FlowBox flow_box;
            public Gtk.FilterListModel model;
        }

        private Library library;
        private Section[] sections = {};
        private Gtk.CustomFilter filter;
        private Gtk.CustomSorter sorter;
        private Gtk.FilterListModel all_of_kind;
        private uint refilter_id = 0;

        public LibraryKind kind { get; private set; }

        /* "all", "movie" or "tv" */
        public string media_filter { get; set; default = "all"; }
        public string search_text { get; set; default = ""; }
        /* "added", "title", "release" or "watched" */
        public string sort_order { get; set; default = "added"; }

        public signal void title_activated (Title title);

        construct {
            library = Library.get_default ();
            filter = new Gtk.CustomFilter (matches_filters);
            sorter = new Gtk.CustomSorter ((a, b) => compare ((Object) a, (Object) b));
            notify["media-filter"].connect (refilter);
            notify["search-text"].connect (refilter);
            notify["sort-order"].connect (() => sorter.changed (Gtk.SorterChange.DIFFERENT));
            library.title_changed.connect (on_title_changed);
        }

        public override void dispose () {
            library.title_changed.disconnect (on_title_changed);
            if (refilter_id != 0) {
                Source.remove (refilter_id);
                refilter_id = 0;
            }
            dispose_template (typeof (LibraryView));
            base.dispose ();
        }

        public void setup (LibraryKind kind) {
            this.kind = kind;
            all_of_kind = new Gtk.FilterListModel (library.titles, new Gtk.CustomFilter ((item) => {
                return in_view (((Title) item).status);
            }));
            all_of_kind.items_changed.connect (update_page);

            if (kind == LibraryKind.WATCHLIST) {
                add_section (_("Continue Watching"), (s) => s == TitleStatus.WATCHING);
                add_section (_("Plan to Watch"), (s) => s == TitleStatus.PLAN_TO_WATCH);
                empty_page.icon_name = "bookmark-new-symbolic";
                empty_page.title = _("Your Watchlist Is Empty");
                empty_page.description = _("Add movies and shows to keep track of what you want to watch");
                empty_page.child = new Gtk.Button.with_mnemonic (_("_Search Movies & Shows")) {
                    action_name = "win.search",
                    halign = Gtk.Align.CENTER,
                    css_classes = { "pill", "suggested-action" },
                };
            } else if (kind == LibraryKind.WATCHED) {
                add_section (null, (s) => s.is_done ());
                empty_page.icon_name = "object-select-symbolic";
                empty_page.title = _("Nothing Watched Yet");
                empty_page.description = _("Movies and shows you finish show up here");
            } else {
                add_section (null, (s) => s == TitleStatus.DROPPED);
                empty_page.icon_name = "media-playback-stop-symbolic";
                empty_page.title = _("No Dropped Titles");
                empty_page.description = _("Drop movies and shows you won’t finish to keep them out of your watchlist");
            }
            update_page ();
        }

        private bool in_view (TitleStatus status) {
            switch (kind) {
            case LibraryKind.WATCHLIST:
                return status.in_watchlist ();
            case LibraryKind.WATCHED:
                return status.is_done ();
            default:
                return status == TitleStatus.DROPPED;
            }
        }

        private delegate bool StatusPredicate (TitleStatus status);

        private void add_section (string? heading, owned StatusPredicate predicate) {
            var section = new Section ();
            var section_filter = new Gtk.EveryFilter ();
            section_filter.append (new Gtk.CustomFilter ((item) => predicate (((Title) item).status)));
            section_filter.append (filter);
            section.model = new Gtk.FilterListModel (library.titles, section_filter);
            var sorted = new Gtk.SortListModel (section.model, sorter);

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            if (heading != null) {
                var label = new Gtk.Label (heading) {
                    xalign = 0,
                    margin_start = 6,
                    css_classes = { "title-4" },
                };
                box.append (label);
                box.update_relation (Gtk.AccessibleRelation.LABELLED_BY, label, null, -1);
            }
            section.flow_box = new Gtk.FlowBox () {
                selection_mode = Gtk.SelectionMode.NONE,
                activate_on_single_click = true,
                homogeneous = true,
                min_children_per_line = 2,
                max_children_per_line = 20,
                row_spacing = 18,
                column_spacing = 12,
                valign = Gtk.Align.START,
            };
            section.flow_box.bind_model (sorted, (item) => {
                var child = new Gtk.FlowBoxChild () {
                    child = new PosterCard ((Title) item),
                    css_classes = { "poster-card" },
                };
                return child;
            });
            section.flow_box.child_activated.connect ((child) => {
                title_activated (((PosterCard) child.child).title);
            });
            box.append (section.flow_box);
            section.header = box;
            section.model.items_changed.connect (update_page);
            sections_box.append (box);
            sections += section;
        }

        private bool matches_filters (Object item) {
            var t = (Title) item;
            if (media_filter == "movie" && !t.is_movie) {
                return false;
            }
            if (media_filter == "tv" && t.is_movie) {
                return false;
            }
            var text = search_text.strip ();
            if (text == "") {
                return true;
            }
            var needle = text.casefold ();
            return t.name.casefold ().contains (needle)
                || (t.original_name != null && t.original_name.casefold ().contains (needle));
        }

        private int compare (Object a, Object b) {
            var x = (Title) a;
            var y = (Title) b;
            int result;
            switch (sort_order) {
            case "title":
                result = x.name.collate (y.name);
                break;
            case "release":
                result = strcmp (y.release_date ?? "", x.release_date ?? "");
                break;
            case "watched":
                result = cmp64 (y.last_watched_at, x.last_watched_at);
                break;
            default:
                result = cmp64 (y.added_at, x.added_at);
                break;
            }
            return result != 0 ? result : x.name.collate (y.name);
        }

        private static int cmp64 (int64 a, int64 b) {
            return a < b ? -1 : (a > b ? 1 : 0);
        }

        private void refilter () {
            filter.changed (Gtk.FilterChange.DIFFERENT);
        }

        private void on_title_changed () {
            // Imports change many titles at once; update the grids once for all of them
            if (refilter_id == 0) {
                refilter_id = Idle.add (() => {
                    refilter_id = 0;
                    update_sections ();
                    return Source.REMOVE;
                });
            }
        }

        private void update_sections () {
            // Status and progress drive sections and sort order
            all_of_kind.filter.changed (Gtk.FilterChange.DIFFERENT);
            foreach (var s in sections) {
                ((Gtk.EveryFilter) s.model.filter).changed (Gtk.FilterChange.DIFFERENT);
            }
            sorter.changed (Gtk.SorterChange.DIFFERENT);
        }

        private void update_page () {
            if (all_of_kind == null) {
                return;
            }
            var any_visible = false;
            foreach (var s in sections) {
                var n = s.model.get_n_items ();
                s.header.visible = n > 0;
                any_visible = any_visible || n > 0;
            }
            if (all_of_kind.get_n_items () == 0) {
                stack.visible_child_name = "empty";
            } else if (!any_visible) {
                stack.visible_child_name = "no-results";
            } else {
                stack.visible_child_name = "content";
            }
        }
    }
}
