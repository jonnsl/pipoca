namespace Pipoca {
    /* A cast or crew member: photo, name and role. Opens the person on TMDB. */
    public class PersonCard : Gtk.Button {
        private const int AVATAR_SIZE = 96;

        private Adw.Avatar avatar;
        private Cancellable cancellable = new Cancellable ();

        public Credit credit { get; construct; }

        public PersonCard (Credit credit) {
            Object (credit: credit);
        }

        construct {
            add_css_class ("flat");
            add_css_class ("person-card");
            tooltip_text = credit.role != "" ? "%s — %s".printf (credit.name, credit.role) : credit.name;
            update_property (Gtk.AccessibleProperty.LABEL, tooltip_text, -1);

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) { width_request = AVATAR_SIZE + 16 };
            avatar = new Adw.Avatar (AVATAR_SIZE, credit.name, true);
            box.append (avatar);
            box.append (new Gtk.Label (credit.name) {
                wrap = true,
                lines = 2,
                ellipsize = Pango.EllipsizeMode.END,
                justify = Gtk.Justification.CENTER,
                max_width_chars = 1,
                hexpand = true,
                css_classes = { "caption-heading" },
            });
            box.append (new Gtk.Label (credit.role) {
                wrap = true,
                lines = 2,
                ellipsize = Pango.EllipsizeMode.END,
                justify = Gtk.Justification.CENTER,
                max_width_chars = 1,
                hexpand = true,
                css_classes = { "caption", "dim-label" },
            });
            child = box;

            clicked.connect (() => {
                var launcher = new Gtk.UriLauncher (credit.tmdb_url);
                launcher.launch.begin (get_root () as Gtk.Window, null, (obj, res) => {
                    try {
                        launcher.launch.end (res);
                    } catch (Error e) {
                        warning ("Can't open %s: %s", credit.tmdb_url, e.message);
                    }
                });
            });

            if (credit.profile_path != null) {
                load_photo.begin ();
            }
        }

        public override void dispose () {
            cancellable.cancel ();
            base.dispose ();
        }

        private async void load_photo () {
            var texture = yield ImageCache.get_default ().load (credit.profile_path, "w185", cancellable);
            if (texture != null) {
                avatar.custom_image = texture;
            }
        }
    }
}
