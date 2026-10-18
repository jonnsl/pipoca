namespace Pipoca {
    [GtkTemplate (ui = "/io/github/jonnsl/Pipoca/pages/season-page.ui")]
    public class SeasonPage : Adw.NavigationPage {
        [GtkChild] private unowned Adw.WindowTitle window_title;
        [GtkChild] private unowned Gtk.Label progress_label;
        [GtkChild] private unowned Gtk.ProgressBar progress_bar;
        [GtkChild] private unowned Gtk.Button season_button;
        [GtkChild] private unowned Gtk.Label overview_label;
        [GtkChild] private unowned Gtk.ListBox episodes_list;

        private Library library;
        private GenericArray<Episode> episodes = new GenericArray<Episode> ();
        private bool all_watched;

        public Title tv_show { get; construct; }
        public Season season { get; construct; }

        public SeasonPage (Title tv_show, Season season) {
            Object (tv_show: tv_show, season: season);
        }

        construct {
            library = Library.get_default ();
            title = season.name;
            window_title.title = season.name;
            window_title.subtitle = tv_show.name;
            overview_label.label = season.overview ?? "";
            overview_label.visible = season.overview != null && season.overview != "";
            library.episodes_changed.connect (on_episodes_changed);
            load ();
        }

        public override void dispose () {
            library.episodes_changed.disconnect (on_episodes_changed);
            dispose_template (typeof (SeasonPage));
            base.dispose ();
        }

        private void on_episodes_changed (Title t) {
            if (t == tv_show) {
                load ();
            }
        }

        private void load () {
            var fresh = library.get_episodes (tv_show, season.season_number);
            if (same_episodes (fresh)) {
                // Only watch state changed; keep the rows so focus and scroll stay put
                for (var i = 0; i < fresh.length; i++) {
                    episodes[i].watched = fresh[i].watched;
                }
                update_progress ();
                return;
            }
            episodes = fresh;
            episodes_list.remove_all ();
            foreach (var e in episodes) {
                var row = new EpisodeRow (e);
                row.toggled.connect (on_episode_toggled);
                row.mark_up_to_here.connect (on_mark_up_to_here);
                episodes_list.append (row);
            }
            update_progress ();
        }

        private bool same_episodes (GenericArray<Episode> other) {
            if (other.length != episodes.length || other.length == 0) {
                return false;
            }
            for (var i = 0; i < other.length; i++) {
                var a = episodes[i];
                var b = other[i];
                if (a.episode_number != b.episode_number || a.name != b.name || a.air_date != b.air_date
                    || a.still_path != b.still_path || a.overview != b.overview || a.runtime != b.runtime) {
                    return false;
                }
            }
            return true;
        }

        private void update_progress () {
            int aired = 0, watched = 0;
            foreach (var e in episodes) {
                if (e.aired) {
                    aired++;
                    if (e.watched) {
                        watched++;
                    }
                }
            }
            all_watched = aired > 0 && watched == aired;
            progress_label.label = _("%d of %d watched").printf (watched, aired);
            progress_bar.fraction = aired > 0 ? (double) watched / aired : 0;
            progress_bar.update_property (Gtk.AccessibleProperty.VALUE_TEXT, progress_label.label, -1);
            season_button.label = all_watched ? _("Mark Season Unwatched") : _("Mark Season Watched");
            season_button.sensitive = aired > 0;
            if (all_watched) {
                season_button.remove_css_class ("suggested-action");
            } else {
                season_button.add_css_class ("suggested-action");
            }
        }

        private GenericArray<Episode> aired_episodes () {
            var result = new GenericArray<Episode> ();
            foreach (var e in episodes) {
                if (e.aired) {
                    result.add (e);
                }
            }
            return result;
        }

        private void on_episode_toggled (Episode e, bool watched) {
            var eps = new GenericArray<Episode> ();
            eps.add (e);
            TitleActions.mark_episodes (this, tv_show, eps, watched);
        }

        private void on_mark_up_to_here (Episode e) {
            TitleActions.mark_episodes (this, tv_show, library.get_episodes_up_to (tv_show, e), true);
        }

        [GtkCallback]
        private void on_season_button_clicked () {
            if (!all_watched) {
                TitleActions.mark_episodes (this, tv_show, aired_episodes (), true);
                return;
            }
            // Unmarking loses watch dates, so confirm first
            var dialog = new Adw.AlertDialog (_("Mark Season Unwatched?"),
                                              _("All episodes of %s will be marked as unwatched").printf (season.name));
            dialog.add_response ("cancel", _("_Cancel"));
            dialog.add_response ("unmark", _("_Mark Unwatched"));
            dialog.set_response_appearance ("unmark", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";
            dialog.response.connect ((response) => {
                if (response == "unmark") {
                    library.set_episodes_watched (tv_show, aired_episodes (), false);
                }
            });
            dialog.present (this);
        }

        [GtkCallback]
        private void on_row_activated (Gtk.ListBoxRow row) {
            ((EpisodeRow) row).expanded = !((EpisodeRow) row).expanded;
        }
    }
}
