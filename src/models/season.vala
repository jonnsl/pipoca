namespace Pipoca {
    public class Season : Object {
        public int64 show_id { get; construct; }
        public int season_number { get; construct; }
        public string name { get; set; default = ""; }
        public string? overview { get; set; }
        public string? poster_path { get; set; }
        public string? air_date { get; set; }
        public int episode_count { get; set; }

        public int aired_count { get; set; }
        public int watched_count { get; set; }

        public Season (int64 show_id, int season_number) {
            Object (show_id: show_id, season_number: season_number);
        }

        public bool is_specials {
            get { return season_number == 0; }
        }

        public static Season from_json (int64 show_id, Json.Object o) {
            var s = new Season (show_id, (int) JsonUtil.integer (o, "season_number"));
            s.name = JsonUtil.str (o, "name") ?? _("Season %d").printf (s.season_number);
            s.overview = JsonUtil.str (o, "overview");
            s.poster_path = JsonUtil.str (o, "poster_path");
            s.air_date = JsonUtil.str (o, "air_date");
            var episodes = JsonUtil.array (o, "episodes");
            s.episode_count = episodes != null ? (int) episodes.get_length () : (int) JsonUtil.integer (o, "episode_count");
            return s;
        }
    }
}
