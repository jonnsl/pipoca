namespace Pipoca {
    [GtkTemplate (ui = "/io/github/jonnsl/Pipoca/widgets/poster-card.ui")]
    public class PosterCard : Gtk.Box {
        [GtkChild] private unowned Poster poster;
        [GtkChild] private unowned Gtk.ProgressBar progress_bar;
        [GtkChild] private unowned Gtk.Label new_badge;
        [GtkChild] private unowned Gtk.Image library_emblem;
        [GtkChild] private unowned Gtk.Label title_label;
        [GtkChild] private unowned Gtk.Label subtitle_label;
        private Gtk.PopoverMenu context_menu;

        public Title title { get; construct; }
        /* Marks titles in the library, for lists that mix in others */
        public bool show_library_emblem { get; set; }

        public PosterCard (Title title) {
            Object (title: title);
        }

        static construct {
            install_action ("card.toggle-watched", null, (w) => {
                var t = ((PosterCard) w).title;
                TitleActions.set_movie_watched (w, t, !t.movie_watched);
            });
            install_action ("card.mark-next", null, (w) => {
                TitleActions.mark_next_watched (w, ((PosterCard) w).title);
            });
            install_action ("card.add", null, (w) => {
                TitleActions.add (w, ((PosterCard) w).title);
            });
            install_action ("card.drop", null, (w) => {
                TitleActions.set_dropped (w, ((PosterCard) w).title, true);
            });
            install_action ("card.resume", null, (w) => {
                TitleActions.set_dropped (w, ((PosterCard) w).title, false);
            });
            install_action ("card.remove", null, (w) => {
                TitleActions.remove (w, ((PosterCard) w).title);
            });
            install_action ("card.open-tmdb", null, (w) => {
                TitleActions.open_on_tmdb (w, ((PosterCard) w).title);
            });
        }

        construct {
            title.bind_property ("name", title_label, "label", BindingFlags.SYNC_CREATE);
            title.bind_property ("name", title_label, "tooltip-text", BindingFlags.SYNC_CREATE);
            title.bind_property ("name", poster, "alternative-text", BindingFlags.SYNC_CREATE);
            title.bind_property ("poster-path", poster, "path", BindingFlags.SYNC_CREATE);
            title.notify.connect (update);
            notify["show-library-emblem"].connect (update);
            library_emblem.update_property (Gtk.AccessibleProperty.LABEL, _("In Library"), -1);
            update ();

            context_menu = new Gtk.PopoverMenu.from_model (null) { has_arrow = false, halign = Gtk.Align.START };
            context_menu.set_parent (this);

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
            title.notify.disconnect (update);
            if (context_menu != null) {
                context_menu.unparent ();
                context_menu = null;
            }
            dispose_template (typeof (PosterCard));
            base.dispose ();
        }

        private void update () {
            if (!title.is_movie && title.status == TitleStatus.DROPPED && title.watched_count > 0) {
                // Where it was left off
                subtitle_label.label = _("%d of %d episodes").printf (title.watched_count, title.aired_count);
            } else if (!title.is_movie && title.status == TitleStatus.WATCHING && title.next_episode != null) {
                subtitle_label.label = title.next_episode.code;
            } else if (!title.is_movie && title.status == TitleStatus.UP_TO_DATE && title.upcoming_episode != null) {
                subtitle_label.label = _("%s · %s").printf (title.upcoming_episode.code,
                                                             Utils.format_upcoming_date (title.upcoming_episode.air_date));
            } else {
                subtitle_label.label = title.describe ();
            }
            library_emblem.visible = show_library_emblem && title.in_library;
            new_badge.visible = title.has_new;
            new_badge.tooltip_text = title.is_movie ? _("Released since you last opened Pipoca")
                                                    : _("New episodes since you last opened Pipoca");
            var fraction = title.progress_fraction;
            progress_bar.visible = fraction >= 0
                && (title.status == TitleStatus.WATCHING || title.status == TitleStatus.DROPPED);
            progress_bar.fraction = fraction;
            progress_bar.tooltip_text = _("%d of %d episodes watched").printf (title.watched_count, title.aired_count);
            progress_bar.update_property (Gtk.AccessibleProperty.VALUE_TEXT, progress_bar.tooltip_text, -1);
        }

        private void show_menu (double x, double y) {
            context_menu.menu_model = TitleActions.build_menu (title, "card");
            context_menu.pointing_to = { (int) x, (int) y, 1, 1 };
            context_menu.popup ();
        }
    }
}
