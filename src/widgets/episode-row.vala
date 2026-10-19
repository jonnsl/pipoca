namespace Pipoca {
    [GtkTemplate (ui = "/io/github/jonnsl/Pipoca/widgets/episode-row.ui")]
    public class EpisodeRow : Gtk.ListBoxRow {
        [GtkChild] private unowned Poster still;
        [GtkChild] private unowned Gtk.Label title_label;
        [GtkChild] private unowned Gtk.Label meta_label;
        [GtkChild] private unowned Gtk.Label overview_label;
        [GtkChild] private unowned Gtk.ToggleButton watched_button;
        [GtkChild] private unowned Gtk.Button reveal_button;

        private Gtk.PopoverMenu? context_menu;
        private bool updating;
        /* The user chose to see this episode's spoilers */
        private bool revealed;

        public Episode episode { get; construct; }
        public bool expanded { get; set; }

        public signal void toggled (Episode episode, bool watched);
        public signal void mark_up_to_here (Episode episode);

        public EpisodeRow (Episode episode) {
            Object (episode: episode);
        }

        static construct {
            install_action ("episode.mark-up-to-here", null, (w) => {
                var row = (EpisodeRow) w;
                row.mark_up_to_here (row.episode);
            });
        }

        construct {
            var e = episode;
            still.path = e.still_path;
            var date = e.aired ? Utils.format_date (e.air_date) : Utils.format_upcoming_date (e.air_date);
            meta_label.label = Utils.join_dot ({ date, Utils.format_runtime (e.runtime) });
            update_spoilers ();
            e.notify["watched"].connect (update_spoilers);
            Spoilers.get_default ().notify["level"].connect (update_spoilers);

            if (!e.aired) {
                add_css_class ("dim-label");
                watched_button.sensitive = false;
                watched_button.tooltip_text = _("Not aired yet");
                action_set_enabled ("episode.mark-up-to-here", false);
            }
            update_watched ();
            e.notify["watched"].connect (update_watched);
            watched_button.toggled.connect (() => {
                if (!updating) {
                    toggled (episode, watched_button.active);
                }
            });

            notify["expanded"].connect (() => {
                overview_label.lines = expanded ? -1 : 2;
                overview_label.ellipsize = expanded ? Pango.EllipsizeMode.NONE : Pango.EllipsizeMode.END;
            });

            var click = new Gtk.GestureClick () { button = Gdk.BUTTON_SECONDARY };
            click.pressed.connect ((n, x, y) => {
                show_menu (x, y);
                click.set_state (Gtk.EventSequenceState.CLAIMED);
            });
            add_controller (click);
            var long_press = new Gtk.GestureLongPress () { touch_only = true };
            long_press.pressed.connect ((x, y) => {
                show_menu (x, y);
                long_press.set_state (Gtk.EventSequenceState.CLAIMED);
            });
            add_controller (long_press);
        }

        public override void dispose () {
            episode.notify["watched"].disconnect (update_watched);
            episode.notify["watched"].disconnect (update_spoilers);
            Spoilers.get_default ().notify["level"].disconnect (update_spoilers);
            if (context_menu != null) {
                context_menu.unparent ();
                context_menu = null;
            }
            dispose_template (typeof (EpisodeRow));
            base.dispose ();
        }

        private void update_watched () {
            updating = true;
            watched_button.active = episode.watched;
            updating = false;
            if (episode.aired) {
                watched_button.tooltip_text = episode.watched ? _("Mark as Unwatched") : _("Mark as Watched");
            }
            watched_button.update_property (Gtk.AccessibleProperty.LABEL, watched_button.tooltip_text, -1);
        }

        private void update_spoilers () {
            var e = episode;
            var spoilers = Spoilers.get_default ();
            var hide_image = !revealed && spoilers.hides_image (e);
            var hide_details = !revealed && spoilers.hides_details (e);

            if (hide_image) {
                still.add_css_class ("spoiler");
            } else {
                still.remove_css_class ("spoiler");
            }
            reveal_button.visible = hide_image;

            if (hide_details || e.name == "") {
                title_label.label = _("Episode %d").printf (e.episode_number);
                still.alternative_text = title_label.label;
            } else {
                title_label.label = "%d. %s".printf (e.episode_number, e.name);
                still.alternative_text = e.name;
            }
            overview_label.label = hide_details ? "" : e.overview ?? "";
            overview_label.visible = overview_label.label != "";
        }

        [GtkCallback]
        private void on_reveal_clicked () {
            revealed = true;
            update_spoilers ();
            grab_focus ();
        }

        private void show_menu (double x, double y) {
            if (!episode.aired) {
                return;
            }
            if (context_menu == null) {
                var menu = new Menu ();
                menu.append (_("Mark Watched _Up to Here"), "episode.mark-up-to-here");
                context_menu = new Gtk.PopoverMenu.from_model (menu) { has_arrow = false, halign = Gtk.Align.START };
                context_menu.set_parent (this);
            }
            context_menu.pointing_to = { (int) x, (int) y, 1, 1 };
            context_menu.popup ();
        }
    }
}
