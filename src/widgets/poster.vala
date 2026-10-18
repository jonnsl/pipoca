namespace Pipoca {
    /**
     * A TMDB image with a fixed size and a placeholder icon until it loads.
     *
     * Set image-width to -1 to fill the available width (backdrops).
     */
    public class Poster : Gtk.Widget {
        private Gtk.Picture picture;
        private Gtk.Image placeholder;
        private Cancellable? cancellable;

        public string? path { get; set; }
        /* TMDB image size, e.g. "w342" */
        public string size { get; set; default = "w342"; }
        public int image_width { get; set; default = 150; }
        public int image_height { get; set; default = 225; }

        public string icon_name {
            owned get { return placeholder.icon_name; }
            set { placeholder.icon_name = value; }
        }

        /* Accessible name, usually the title */
        public string? alternative_text { get; set; }

        public Gdk.Paintable? paintable {
            get { return picture.paintable; }
        }

        static construct {
            set_css_name ("poster");
            set_accessible_role (Gtk.AccessibleRole.IMG);
        }

        construct {
            overflow = Gtk.Overflow.HIDDEN;
            placeholder = new Gtk.Image.from_icon_name ("video-x-generic-symbolic") {
                pixel_size = 32,
                css_classes = { "dim-label" },
            };
            placeholder.set_parent (this);
            picture = new Gtk.Picture () {
                content_fit = Gtk.ContentFit.COVER,
                can_shrink = true,
                visible = false,
            };
            picture.set_parent (this);

            notify["alternative-text"].connect (() => {
                update_property (Gtk.AccessibleProperty.LABEL, alternative_text ?? "", -1);
            });
            notify["path"].connect (reload);
            notify["size"].connect (reload);
            notify["image-width"].connect (queue_resize);
            notify["image-height"].connect (queue_resize);
        }

        public override void dispose () {
            if (cancellable != null) {
                cancellable.cancel ();
            }
            placeholder.unparent ();
            picture.unparent ();
            base.dispose ();
        }

        private void reload () {
            if (cancellable != null) {
                cancellable.cancel ();
                cancellable = null;
            }
            picture.paintable = null;
            picture.visible = false;
            placeholder.visible = true;
            if (path == null || path == "") {
                return;
            }
            cancellable = new Cancellable ();
            var c = cancellable;
            ImageCache.get_default ().load.begin (path, size, c, (obj, res) => {
                var texture = ImageCache.get_default ().load.end (res);
                if (c.is_cancelled () || texture == null) {
                    return;
                }
                picture.paintable = texture;
                picture.visible = true;
                placeholder.visible = false;
            });
        }

        public override Gtk.SizeRequestMode get_request_mode () {
            return Gtk.SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure (Gtk.Orientation orientation, int for_size,
                                      out int minimum, out int natural,
                                      out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = natural_baseline = -1;
            if (orientation == Gtk.Orientation.HORIZONTAL) {
                minimum = natural = int.max (image_width, 0);
            } else {
                minimum = natural = int.max (image_height, 0);
            }
        }

        public override void size_allocate (int width, int height, int baseline) {
            picture.allocate (width, height, baseline, null);
            int min, nat;
            placeholder.measure (Gtk.Orientation.HORIZONTAL, -1, out min, out nat, null, null);
            var w = int.min (nat, width);
            placeholder.measure (Gtk.Orientation.VERTICAL, -1, out min, out nat, null, null);
            var h = int.min (nat, height);
            var t = new Gsk.Transform ().translate ({ (width - w) / 2, (height - h) / 2 });
            placeholder.allocate (w, h, -1, t);
        }
    }
}
