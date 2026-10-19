namespace Pipoca {
    [GtkTemplate (ui = "/io/github/jonnsl/Pipoca/pages/details-page.ui")]
    public class DetailsPage : Adw.NavigationPage {
        /* Room for the header bar when there's no backdrop, and how far the header overlaps it */
        private const int MARGIN_NO_BACKDROP = 60;
        private const int MARGIN_WITH_BACKDROP = 200;

        [GtkChild] private unowned Gtk.Stack stack;
        [GtkChild] private unowned Adw.StatusPage error_page;
        [GtkChild] private unowned Gtk.Overlay top_overlay;
        [GtkChild] private unowned Adw.Clamp content_clamp;
        [GtkChild] private unowned Poster backdrop;
        [GtkChild] private unowned Poster poster;
        [GtkChild] private unowned Gtk.Label title_label;
        [GtkChild] private unowned Gtk.Label meta_label;
        [GtkChild] private unowned Gtk.Label network_label;
        [GtkChild] private unowned Gtk.Button primary_button;
        [GtkChild] private unowned Gtk.Button trailer_button;
        [GtkChild] private unowned Gtk.MenuButton library_button;
        [GtkChild] private unowned Adw.ButtonContent library_button_content;
        [GtkChild] private unowned Gtk.ListBox next_list;
        [GtkChild] private unowned Adw.ActionRow next_row;
        [GtkChild] private unowned Gtk.Button next_button;
        [GtkChild] private unowned Gtk.Box overview_box;
        [GtkChild] private unowned Gtk.Label overview_label;
        [GtkChild] private unowned Gtk.Box seasons_box;
        [GtkChild] private unowned Gtk.ListBox seasons_list;
        [GtkChild] private unowned Gtk.Box cast_box;
        [GtkChild] private unowned Gtk.Label cast_label;
        [GtkChild] private unowned Gtk.Box cast_list;
        [GtkChild] private unowned Gtk.Box more_box;
        [GtkChild] private unowned Gtk.ListBox info_list;

        private Library library;
        private Shelf more_shelf;
        /* YouTube video key */
        private string? trailer_key;
        private Cancellable cancellable = new Cancellable ();
        private uint update_id = 0;

        public Title title_object { get; construct; }

        /* Backs the "Notify Me" check item */
        public bool notify_me {
            get { return title_object.notify_enabled; }
            set { library.set_notify (title_object, value); }
        }

        public DetailsPage (Title title) {
            Object (title_object: title);
        }

        static construct {
            install_action ("details.refresh", null, (w) => ((DetailsPage) w).refresh ());
            install_action ("details.open-tmdb", null, (w) => {
                TitleActions.open_on_tmdb (w, ((DetailsPage) w).title_object);
            });
            install_action ("details.copy-link", null, (w) => {
                TitleActions.copy_link (w, ((DetailsPage) w).title_object);
            });
            install_action ("details.drop", null, (w) => {
                TitleActions.set_dropped (w, ((DetailsPage) w).title_object, true);
            });
            install_action ("details.resume", null, (w) => {
                TitleActions.set_dropped (w, ((DetailsPage) w).title_object, false);
            });
            install_action ("details.remove", null, (w) => {
                TitleActions.remove (w, ((DetailsPage) w).title_object);
            });
            install_property_action ("details.notify", "notify-me");
            install_action ("details.trailer", null, (w) => ((DetailsPage) w).open_trailer ());
        }

        construct {
            library = Library.get_default ();
            top_overlay.set_measure_overlay (content_clamp, true);
            title_object.bind_property ("name", this, "title", BindingFlags.SYNC_CREATE);
            title_object.notify.connect (queue_update);
            title_object.notify["notify-enabled"].connect (on_notify_enabled_changed);
            library.episodes_changed.connect (on_episodes_changed);
            Spoilers.get_default ().notify["level"].connect (update_next);

            update ();
            action_set_enabled ("details.trailer", false);
            cast_list.update_relation (Gtk.AccessibleRelation.LABELLED_BY, cast_label, null, -1);
            load_extras.begin ();
            setup_recommendations ();
            if (title_object.has_details) {
                stack.visible_child_name = "content";
                if (library.is_stale (title_object)) {
                    load.begin (false);
                }
            } else {
                load.begin (false);
            }
        }

        public override void dispose () {
            cancellable.cancel ();
            title_object.notify.disconnect (queue_update);
            title_object.notify["notify-enabled"].disconnect (on_notify_enabled_changed);
            library.episodes_changed.disconnect (on_episodes_changed);
            Spoilers.get_default ().notify["level"].disconnect (update_next);
            if (update_id != 0) {
                Source.remove (update_id);
                update_id = 0;
            }
            dispose_template (typeof (DetailsPage));
            base.dispose ();
        }

        public void refresh () {
            load.begin (true);
            load_extras.begin ();
            load_recommendations.begin ();
        }

        private void open_trailer () {
            if (trailer_key == null) {
                return;
            }
            var url = "https://www.youtube.com/watch?v=" + Uri.escape_string (trailer_key);
            var launcher = new Gtk.UriLauncher (url);
            launcher.launch.begin (get_root () as Gtk.Window, null, (obj, res) => {
                try {
                    launcher.launch.end (res);
                } catch (Error e) {
                    warning ("Can't open %s: %s", url, e.message);
                }
            });
        }

        /* Cast, crew and trailer, which aren't kept in the library; hidden when they can't be loaded */
        private async void load_extras () {
            var t = title_object;
            Json.Object extras;
            try {
                string[] parts = { t.is_movie ? "credits" : "aggregate_credits", "videos" };
                extras = yield library.tmdb.get_extras (t.media_type, t.id, parts, cancellable);
            } catch (Error e) {
                if (!(e is IOError.CANCELLED)) {
                    debug ("Can't load extras of %s: %s", t.key, e.message);
                }
                return;
            }
            Gtk.Widget? child;
            while ((child = cast_list.get_first_child ()) != null) {
                cast_list.remove (child);
            }
            var credits = Credit.parse (extras, t.media_type);
            foreach (var c in credits) {
                cast_list.append (new PersonCard (c));
            }
            cast_box.visible = credits.length > 0;

            trailer_key = TmdbClient.pick_trailer (extras, library.tmdb.language.split ("-")[0]);
            action_set_enabled ("details.trailer", trailer_key != null);
            trailer_button.visible = trailer_key != null;
        }

        private void setup_recommendations () {
            more_shelf = new Shelf (DiscoverList.recommendations (_("More Like This"), title_object));
            more_shelf.title_activated.connect ((t) => {
                var win = Window.of (this);
                if (win != null) {
                    win.show_title (t);
                }
            });
            more_shelf.see_all.connect ((list) => {
                var nav = (Adw.NavigationView) get_ancestor (typeof (Adw.NavigationView));
                nav.push (new DiscoverListPage (list));
            });
            more_box.append (more_shelf);
            load_recommendations.begin ();
        }

        /* Shown only when there are some; offline, the page works without them */
        private async void load_recommendations () {
            yield more_shelf.load ();
            // Unless the page was closed meanwhile
            if (!cancellable.is_cancelled ()) {
                more_box.visible = more_shelf.has_items;
            }
        }

        private async void load (bool force) {
            var silent = title_object.has_details;
            if (!silent) {
                stack.visible_child_name = "loading";
            }
            try {
                yield library.refresh (title_object, force || !title_object.has_details, cancellable);
                stack.visible_child_name = "content";
            } catch (IOError.CANCELLED e) {
                // Page closed
            } catch (Error e) {
                warning ("Can't load %s: %s", title_object.key, e.message);
                if (silent) {
                    // Cached data is still good; just say the refresh failed
                    var win = Window.of (this);
                    if (win != null && force) {
                        win.add_toast (new Adw.Toast (_("Can’t refresh metadata")));
                    }
                } else {
                    error_page.description = e.message;
                    stack.visible_child_name = "error";
                }
            }
        }

        [GtkCallback]
        private void on_retry_clicked () {
            load.begin (true);
        }

        private void queue_update () {
            if (update_id == 0) {
                update_id = Idle.add (() => {
                    update_id = 0;
                    update ();
                    return Source.REMOVE;
                });
            }
        }

        private void on_notify_enabled_changed () {
            notify_property ("notify-me");
        }

        private void on_episodes_changed (Title show) {
            if (show == title_object) {
                update_seasons ();
            }
        }

        private void update () {
            var t = title_object;
            backdrop.path = t.backdrop_path;
            backdrop.visible = t.backdrop_path != null;
            content_clamp.margin_top = t.backdrop_path != null ? MARGIN_WITH_BACKDROP : MARGIN_NO_BACKDROP;
            poster.path = t.poster_path;
            poster.alternative_text = t.name;
            title_label.label = t.name;

            string? rating = t.vote_average > 0 ? "★ %.1f".printf (t.vote_average) : null;
            string? runtime = t.is_movie ? Utils.format_runtime (t.runtime) : null;
            meta_label.label = Utils.join_dot ({ t.year, t.type_label, runtime, t.genres, rating });

            if (t.is_movie) {
                network_label.visible = false;
            } else {
                string? seasons = t.number_of_seasons > 0
                    ? ngettext ("%d season", "%d seasons", t.number_of_seasons).printf (t.number_of_seasons) : null;
                network_label.label = Utils.join_dot ({ t.networks, Utils.tmdb_status_label (t.tmdb_status), seasons });
                network_label.visible = network_label.label != "";
            }

            update_buttons ();
            update_next ();

            overview_label.label = t.overview ?? "";
            overview_box.visible = t.overview != null && t.overview != "";

            update_info ();
            update_seasons ();
        }

        private void update_buttons () {
            var t = title_object;
            primary_button.remove_css_class ("suggested-action");
            primary_button.visible = true;
            if (!t.in_library) {
                primary_button.label = _("Add to Watchlist");
                primary_button.add_css_class ("suggested-action");
            } else if (t.is_dropped) {
                primary_button.label = _("Resume Watching");
            } else if (t.is_movie) {
                primary_button.label = t.movie_watched ? _("Mark as Unwatched") : _("Mark as Watched");
                if (!t.movie_watched) {
                    primary_button.add_css_class ("suggested-action");
                }
            } else if (t.next_episode != null) {
                primary_button.label = _("Mark %s as Watched").printf (t.next_episode.code);
                primary_button.add_css_class ("suggested-action");
            } else {
                primary_button.visible = false;
            }

            library_button.visible = t.in_library;
            library_button_content.icon_name = t.is_dropped ? "media-playback-stop-symbolic" : "object-select-symbolic";
            var menu = new Menu ();
            // Nothing to notify about for dropped titles or movies already watched
            if (!t.is_dropped && !(t.is_movie && t.movie_watched)) {
                var notify_section = new Menu ();
                notify_section.append (_("_Notify Me"), "details.notify");
                menu.append_section (null, notify_section);
            }
            var library_section = new Menu ();
            if (t.is_dropped) {
                library_section.append (_("Resu_me Watching"), "details.resume");
            } else {
                library_section.append (_("_Drop"), "details.drop");
            }
            library_section.append (_("_Remove from Library"), "details.remove");
            menu.append_section (null, library_section);
            library_button.menu_model = menu;
            switch (t.status) {
            case TitleStatus.PLAN_TO_WATCH:
                library_button_content.label = _("In Watchlist");
                break;
            default:
                library_button_content.label = t.status.to_label ();
                break;
            }
        }

        private void update_next () {
            var t = title_object;
            if (t.is_movie || !t.in_library || t.is_dropped) {
                next_list.visible = false;
                return;
            }
            if (t.next_episode != null) {
                next_row.title = _("Next: %s").printf (Spoilers.get_default ().describe (t.next_episode));
                next_row.subtitle = Utils.format_date (t.next_episode.air_date);
                next_button.visible = true;
                next_list.visible = true;
            } else if (t.upcoming_episode != null) {
                next_row.title = _("Next: %s").printf (Spoilers.get_default ().describe (t.upcoming_episode));
                next_row.subtitle = _("Airs %s").printf (Utils.format_upcoming_date (t.upcoming_episode.air_date));
                next_button.visible = false;
                next_list.visible = true;
            } else {
                next_list.visible = false;
            }
        }

        private void add_info (string title, string? value) {
            if (value == null || value == "") {
                return;
            }
            var row = new Adw.ActionRow () {
                use_markup = false,
                title = title,
                subtitle = value,
                subtitle_selectable = true,
                css_classes = { "property" },
            };
            info_list.append (row);
        }

        private void update_info () {
            var t = title_object;
            info_list.remove_all ();
            add_info (_("Original Title"), t.original_name);
            add_info (_("Original Language"), Utils.language_name (t.original_language));
            add_info (_("Status"), Utils.tmdb_status_label (t.tmdb_status));
            if (t.is_movie) {
                add_info (_("Release Date"), Utils.format_date (t.release_date));
                add_info (_("Runtime"), Utils.format_runtime (t.runtime));
            } else {
                add_info (_("First Aired"), Utils.format_date (t.release_date));
                add_info (_("Created By"), t.creators);
                add_info (_("Network"), t.networks);
                if (t.number_of_episodes > 0) {
                    add_info (_("Episodes"), t.number_of_episodes.to_string ());
                }
                add_info (_("Episode Runtime"), Utils.format_runtime (t.runtime));
            }
            add_info (_("Genres"), t.genres);
            info_list.get_parent ().visible = info_list.get_first_child () != null;
        }

        private void update_seasons () {
            seasons_list.remove_all ();
            if (title_object.is_movie) {
                seasons_box.visible = false;
                return;
            }
            var seasons = library.get_seasons (title_object);
            seasons_box.visible = seasons.length > 0;
            foreach (var s in seasons) {
                seasons_list.append (new SeasonRow (s));
            }
        }

        [GtkCallback]
        private void on_primary_clicked () {
            var t = title_object;
            if (!t.in_library) {
                TitleActions.add (this, t);
            } else if (t.is_dropped) {
                TitleActions.set_dropped (this, t, false);
            } else if (t.is_movie) {
                TitleActions.set_movie_watched (this, t, !t.movie_watched);
            } else {
                TitleActions.mark_next_watched (this, t);
            }
        }

        [GtkCallback]
        private void on_next_clicked () {
            TitleActions.mark_next_watched (this, title_object);
        }

        [GtkCallback]
        private void on_season_activated (Gtk.ListBoxRow row) {
            var season = ((SeasonRow) row).season;
            var nav = (Adw.NavigationView) get_ancestor (typeof (Adw.NavigationView));
            nav.push (new SeasonPage (title_object, season));
        }
    }

    private class SeasonRow : Adw.ActionRow {
        public Season season { get; construct; }

        public SeasonRow (Season season) {
            Object (season: season);
        }

        construct {
            activatable = true;
            use_markup = false;
            title = season.name;
            string? count = season.episode_count > 0
                ? ngettext ("%d episode", "%d episodes", season.episode_count).printf (season.episode_count) : null;
            string? year = season.air_date != null && season.air_date.length >= 4 ? season.air_date.substring (0, 4) : null;
            subtitle = Utils.join_dot ({ count, year });

            if (season.aired_count > 0) {
                var progress_text = _("%d/%d").printf (season.watched_count, season.aired_count);
                var bar = new Gtk.ProgressBar () {
                    fraction = (double) season.watched_count / season.aired_count,
                    valign = Gtk.Align.CENTER,
                    width_request = 80,
                };
                bar.update_property (Gtk.AccessibleProperty.VALUE_TEXT,
                                     _("%d of %d episodes watched").printf (season.watched_count, season.aired_count), -1);
                var label = new Gtk.Label (progress_text) {
                    css_classes = { "dim-label", "numeric", "caption" },
                    width_chars = 5,
                    xalign = 1,
                };
                add_suffix (bar);
                add_suffix (label);
            }
            add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
        }
    }
}
