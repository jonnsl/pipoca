namespace Pipoca {
    /* Upcoming episodes and movie releases from the library, by date */
    [GtkTemplate (ui = "/io/github/jonnsl/Pipoca/pages/upcoming-view.ui")]
    public class UpcomingView : Adw.Bin {
        [GtkChild] private unowned Gtk.Stack stack;
        [GtkChild] private unowned Gtk.Box sections_box;

        private Library library;
        private uint rebuild_id = 0;
        private uint midnight_id = 0;

        /* "all", "movie" or "tv" */
        public string media_filter { get; set; default = "all"; }
        public string search_text { get; set; default = ""; }

        public signal void title_activated (Title title);

        construct {
            library = Library.get_default ();
            library.title_changed.connect (queue_rebuild);
            library.episodes_changed.connect (queue_rebuild);
            Spoilers.get_default ().notify["level"].connect (queue_rebuild);
            notify["media-filter"].connect (queue_rebuild);
            notify["search-text"].connect (queue_rebuild);
            rebuild ();
            schedule_midnight ();
        }

        public override void dispose () {
            library.title_changed.disconnect (queue_rebuild);
            library.episodes_changed.disconnect (queue_rebuild);
            Spoilers.get_default ().notify["level"].disconnect (queue_rebuild);
            if (rebuild_id != 0) {
                Source.remove (rebuild_id);
                rebuild_id = 0;
            }
            if (midnight_id != 0) {
                Source.remove (midnight_id);
                midnight_id = 0;
            }
            dispose_template (typeof (UpcomingView));
            base.dispose ();
        }

        /* Today becomes Tomorrow at midnight */
        private void schedule_midnight () {
            var now = new DateTime.now_local ();
            var midnight = new DateTime.local (now.get_year (), now.get_month (), now.get_day_of_month (), 0, 0, 0).add_days (1);
            var seconds = (uint) (midnight.difference (now) / TimeSpan.SECOND) + 1;
            midnight_id = Timeout.add_seconds (seconds, () => {
                midnight_id = 0;
                rebuild ();
                schedule_midnight ();
                return Source.REMOVE;
            });
        }

        private void queue_rebuild () {
            // Imports and refreshes change many titles at once
            if (rebuild_id == 0) {
                rebuild_id = Idle.add (() => {
                    rebuild_id = 0;
                    rebuild ();
                    return Source.REMOVE;
                });
            }
        }

        private bool matches_filters (Title t) {
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

        private void rebuild () {
            Gtk.Widget? child;
            while ((child = sections_box.get_first_child ()) != null) {
                sections_box.remove (child);
            }

            var today = Utils.today ();
            var tomorrow = Utils.days_from_today (1);
            var week_end = Utils.days_from_today (6);
            var releases = library.get_releases (today);
            if (releases.length == 0) {
                stack.visible_child_name = "empty";
                return;
            }

            Gtk.ListBox? list = null;
            string? current = null;
            // Later on, only the next episode of each show; a whole season can be scheduled
            var later_shows = new GenericSet<string> (str_hash, str_equal);
            foreach (var r in releases) {
                if (!matches_filters (r.title)) {
                    continue;
                }
                string heading;
                if (r.date == today) {
                    heading = _("Today");
                } else if (r.date == tomorrow) {
                    heading = _("Tomorrow");
                } else if (r.date <= week_end) {
                    heading = _("This Week");
                } else {
                    heading = _("Later");
                    if (r.episode != null) {
                        if (r.title.key in later_shows) {
                            continue;
                        }
                        later_shows.add (r.title.key);
                    }
                }
                if (heading != current) {
                    current = heading;
                    list = add_section (heading);
                }
                list.append (new UpcomingRow (r));
            }
            stack.visible_child_name = list != null ? "content" : "no-results";
        }

        private Gtk.ListBox add_section (string heading) {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            var label = new Gtk.Label (heading) {
                xalign = 0,
                css_classes = { "title-4" },
            };
            box.append (label);
            var list = new Gtk.ListBox () {
                selection_mode = Gtk.SelectionMode.NONE,
                css_classes = { "boxed-list" },
            };
            list.update_relation (Gtk.AccessibleRelation.LABELLED_BY, label, null, -1);
            list.row_activated.connect ((row) => title_activated (((UpcomingRow) row).release.title));
            box.append (list);
            sections_box.append (box);
            return list;
        }
    }

    private class UpcomingRow : Adw.ActionRow {
        public Release release { get; construct; }

        public UpcomingRow (Release release) {
            Object (release: release);
        }

        construct {
            var t = release.title;
            activatable = true;
            use_markup = false;
            title = t.name;
            subtitle = release.episode != null
                ? Spoilers.get_default ().describe (release.episode) : _("Movie release");

            var poster = new Poster () {
                size = "w154",
                image_width = 46,
                image_height = 69,
                path = t.poster_path,
                alternative_text = t.name,
                valign = Gtk.Align.CENTER,
                margin_top = 6,
                margin_bottom = 6,
                css_classes = { "small" },
            };
            add_prefix (poster);

            var date = new Gtk.Label (Utils.format_upcoming_date (release.date)) {
                css_classes = { "dim-label", "numeric" },
            };
            add_suffix (date);

            var bell = new Gtk.ToggleButton () {
                valign = Gtk.Align.CENTER,
                tooltip_text = _("Notify Me"),
                css_classes = { "flat", "circular" },
            };
            t.bind_property ("notify-enabled", bell, "active", BindingFlags.SYNC_CREATE);
            bell.toggled.connect (() => Library.get_default ().set_notify (t, bell.active));
            bell.bind_property ("active", bell, "icon-name", BindingFlags.SYNC_CREATE, (b, from, ref to) => {
                to = from.get_boolean () ? "preferences-system-notifications-symbolic" : "notifications-disabled-symbolic";
                return true;
            });
            add_suffix (bell);
            add_suffix (new Gtk.Image.from_icon_name ("go-next-symbolic"));
        }
    }
}
