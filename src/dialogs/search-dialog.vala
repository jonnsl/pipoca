namespace Pipoca {
    [GtkTemplate (ui = "/io/github/jonnsl/Pipoca/dialogs/search-dialog.ui")]
    public class SearchDialog : Adw.Dialog {
        [GtkChild] private unowned Gtk.SearchEntry search_entry;
        [GtkChild] private unowned Adw.ToggleGroup filter_group;
        [GtkChild] private unowned Gtk.Stack stack;
        [GtkChild] private unowned Adw.StatusPage error_page;
        [GtkChild] private unowned Gtk.ListBox results_list;

        private Cancellable? cancellable;

        public signal void title_activated (Title title);

        construct {
            filter_group.notify["active-name"].connect (search);
        }

        public override void dispose () {
            if (cancellable != null) {
                cancellable.cancel ();
            }
            dispose_template (typeof (SearchDialog));
            base.dispose ();
        }

        [GtkCallback]
        private void on_search_changed () {
            search ();
        }

        [GtkCallback]
        private void on_search_activate () {
            search ();
        }

        private SearchFilter get_filter () {
            switch (filter_group.active_name) {
            case "movie":
                return SearchFilter.MOVIES;
            case "tv":
                return SearchFilter.SHOWS;
            default:
                return SearchFilter.ALL;
            }
        }

        private void search () {
            if (cancellable != null) {
                cancellable.cancel ();
            }
            var text = search_entry.text.strip ();
            if (text == "") {
                cancellable = null;
                stack.visible_child_name = "initial";
                return;
            }
            cancellable = new Cancellable ();
            run_search.begin (text, get_filter (), cancellable);
        }

        private async void run_search (string text, SearchFilter filter, Cancellable c) {
            stack.visible_child_name = "loading";
            GenericArray<Title> results;
            try {
                results = yield Library.get_default ().tmdb.search (text, filter, c);
            } catch (IOError.CANCELLED e) {
                return;
            } catch (Error e) {
                if (c.is_cancelled ()) {
                    return;
                }
                error_page.description = e.message;
                stack.visible_child_name = "error";
                return;
            }
            if (c.is_cancelled ()) {
                return;
            }
            results_list.remove_all ();
            foreach (var t in results) {
                results_list.append (new SearchResultRow (t));
            }
            stack.visible_child_name = results.length > 0 ? "results" : "empty";
        }

        [GtkCallback]
        private void on_row_activated (Gtk.ListBoxRow row) {
            title_activated (((SearchResultRow) row).result);
        }
    }

    /* A search result with a poster and an add button */
    private class SearchResultRow : Adw.ActionRow {
        private Gtk.Button add_button;
        private Library library;

        public Title result { get; construct; }

        public SearchResultRow (Title result) {
            Object (result: result);
        }

        construct {
            library = Library.get_default ();
            activatable = true;
            use_markup = false;
            title = result.name;
            subtitle = result.overview != null && result.overview != ""
                ? "%s\n%s".printf (result.describe (), result.overview)
                : result.describe ();
            subtitle_lines = 3;

            var poster = new Poster () {
                size = "w154",
                image_width = 46,
                image_height = 69,
                path = result.poster_path,
                valign = Gtk.Align.CENTER,
                margin_top = 6,
                margin_bottom = 6,
                css_classes = { "small" },
            };
            add_prefix (poster);

            add_button = new Gtk.Button () {
                valign = Gtk.Align.CENTER,
                css_classes = { "flat", "circular" },
            };
            add_button.clicked.connect (on_add_clicked);
            add_suffix (add_button);
            update ();
            library.title_changed.connect (on_title_changed);
        }

        public override void dispose () {
            library.title_changed.disconnect (on_title_changed);
            base.dispose ();
        }

        private void on_title_changed (Title t) {
            if (t.media_type == result.media_type && t.id == result.id) {
                update ();
            }
        }

        private void update () {
            var in_library = library.contains (result.media_type, result.id);
            add_button.icon_name = in_library ? "object-select-symbolic" : "list-add-symbolic";
            add_button.tooltip_text = in_library ? _("In Library") : _("Add to Watchlist");
            add_button.update_property (Gtk.AccessibleProperty.LABEL, add_button.tooltip_text, -1);
            add_button.sensitive = !in_library;
        }

        private void on_add_clicked () {
            TitleActions.add (this, library.intern (result));
        }
    }
}
