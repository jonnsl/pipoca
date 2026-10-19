namespace Pipoca {
    public enum SpoilerLevel {
        NONE,
        /* Blur the stills of unwatched episodes */
        IMAGES,
        /* Also hide their names and overviews */
        DETAILS,
    }

    /* What the user wants hidden of episodes they haven't watched yet */
    public class Spoilers : Object {
        private static Spoilers? instance;

        private Settings settings;

        public SpoilerLevel level { get; private set; }

        public static Spoilers get_default () {
            if (instance == null) {
                instance = new Spoilers ();
            }
            return instance;
        }

        construct {
            settings = new Settings (Config.APPLICATION_ID);
            settings.changed["hide-spoilers"].connect (update);
            settings.changed["spoiler-level"].connect (update);
            update ();
        }

        private void update () {
            SpoilerLevel l;
            if (!settings.get_boolean ("hide-spoilers")) {
                l = SpoilerLevel.NONE;
            } else if (settings.get_string ("spoiler-level") == "details") {
                l = SpoilerLevel.DETAILS;
            } else {
                l = SpoilerLevel.IMAGES;
            }
            if (l != level) {
                level = l;
            }
        }

        public bool hides_image (Episode e) {
            return level != SpoilerLevel.NONE && !e.watched;
        }

        public bool hides_details (Episode e) {
            return level == SpoilerLevel.DETAILS && !e.watched;
        }

        /* "S2 E5 · Title", or just "S2 E5" if the title would spoil it */
        public string describe (Episode e) {
            return hides_details (e) ? e.code : e.describe ();
        }
    }
}
