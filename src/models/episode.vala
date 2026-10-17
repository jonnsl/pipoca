namespace Aperture {
    public class Episode : Object {
        public int64 show_id { get; construct; }
        public int season_number { get; construct; }
        public int episode_number { get; construct; }
        public string name { get; set; default = ""; }
        public string? overview { get; set; }
        public string? still_path { get; set; }
        public string? air_date { get; set; }
        public int runtime { get; set; }
        public bool watched { get; set; }

        public Episode (int64 show_id, int season_number, int episode_number) {
            Object (show_id: show_id, season_number: season_number, episode_number: episode_number);
        }

        public bool aired {
            get { return air_date != null && air_date != "" && air_date <= Utils.today (); }
        }

        /* "S2 E5" */
        public string code {
            owned get { return _("S%d E%d").printf (season_number, episode_number); }
        }

        /* "S2 E5 · Title" */
        public string describe () {
            return name == "" ? code : "%s · %s".printf (code, name);
        }

        public static Episode from_json (int64 show_id, Json.Object o) {
            var e = new Episode (show_id, (int) JsonUtil.integer (o, "season_number"), (int) JsonUtil.integer (o, "episode_number"));
            e.name = JsonUtil.str (o, "name") ?? "";
            e.overview = JsonUtil.str (o, "overview");
            e.still_path = JsonUtil.str (o, "still_path");
            e.air_date = JsonUtil.str (o, "air_date");
            e.runtime = (int) JsonUtil.integer (o, "runtime");
            return e;
        }
    }
}
