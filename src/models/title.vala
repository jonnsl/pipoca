namespace Aperture {
    public enum MediaType {
        MOVIE,
        TV;

        public string to_api_string () {
            return this == MOVIE ? "movie" : "tv";
        }

        public static bool try_parse (string? s, out MediaType type) {
            type = MOVIE;
            if (s == "movie") {
                return true;
            }
            if (s == "tv") {
                type = TV;
                return true;
            }
            return false;
        }
    }

    public enum TitleStatus {
        NONE,
        PLAN_TO_WATCH,
        WATCHING,
        UP_TO_DATE,
        WATCHED,
        /* Set by the user: started but won't finish */
        DROPPED;

        public string to_label () {
            switch (this) {
            case PLAN_TO_WATCH:
                return _("Plan to Watch");
            case WATCHING:
                return C_("title status", "Watching");
            case UP_TO_DATE:
                return _("Up to Date");
            case WATCHED:
                return C_("title status", "Watched");
            case DROPPED:
                return C_("title status", "Dropped");
            default:
                return "";
            }
        }

        public bool in_watchlist () {
            return this == PLAN_TO_WATCH || this == WATCHING;
        }

        public bool is_done () {
            return this == UP_TO_DATE || this == WATCHED;
        }
    }

    /**
     * A movie or a TV show. Metadata comes from TMDB; the progress fields are
     * derived from watch events by {@link Library}.
     */
    public class Title : Object {
        public MediaType media_type { get; construct; }
        public int64 id { get; construct; }

        public string name { get; set; default = ""; }
        public string? original_name { get; set; }
        public string? original_language { get; set; }
        public string? overview { get; set; }
        public string? poster_path { get; set; }
        public string? backdrop_path { get; set; }
        public string? release_date { get; set; }
        /* Movie runtime, or typical episode runtime for shows, in minutes */
        public int runtime { get; set; }
        public string? genres { get; set; }
        public double vote_average { get; set; }
        public string? tmdb_status { get; set; }
        public string? creators { get; set; }
        public string? networks { get; set; }
        public int number_of_seasons { get; set; }
        public int number_of_episodes { get; set; }

        public bool in_library { get; set; }
        public int64 added_at { get; set; }
        public int64 refreshed_at { get; set; }
        /* When the user dropped the title, or 0 */
        public int64 dropped_at { get; set; }
        /* "Notify Me": send notifications for new episodes or the release */
        public bool notify_enabled { get; set; default = true; }

        public int aired_count { get; set; }
        public int watched_count { get; set; }
        public int total_count { get; set; }
        public bool movie_watched { get; set; }
        /* Next aired episode the user hasn't watched */
        public Episode? next_episode { get; set; }
        /* Next episode that hasn't aired yet */
        public Episode? upcoming_episode { get; set; }
        public int64 last_watched_at { get; set; }
        /* Has an episode or release since the user last opened the app */
        public bool has_new { get; set; }
        public TitleStatus status { get; set; default = TitleStatus.NONE; }

        public Title (MediaType media_type, int64 id) {
            Object (media_type: media_type, id: id);
        }

        public string key {
            owned get { return make_key (media_type, id); }
        }

        public static string make_key (MediaType media_type, int64 id) {
            return "%s:%lld".printf (media_type.to_api_string (), id);
        }

        public static bool try_parse_key (string key, out MediaType media_type, out int64 id) {
            media_type = MediaType.MOVIE;
            id = 0;
            var parts = key.split (":");
            return parts.length == 2 && MediaType.try_parse (parts[0], out media_type)
                   && int64.try_parse (parts[1], out id) && id > 0;
        }

        public bool is_movie {
            get { return media_type == MediaType.MOVIE; }
        }

        public bool is_dropped {
            get { return dropped_at > 0; }
        }

        public bool has_details {
            get { return refreshed_at > 0; }
        }

        public bool is_ended {
            get { return tmdb_status == "Ended" || tmdb_status == "Canceled"; }
        }

        public string year {
            owned get {
                if (release_date != null && release_date.length >= 4) {
                    return release_date.substring (0, 4);
                }
                return "";
            }
        }

        public string type_label {
            owned get { return is_movie ? _("Movie") : _("TV Show"); }
        }

        public string tmdb_url {
            owned get { return "https://www.themoviedb.org/%s/%lld".printf (media_type.to_api_string (), id); }
        }

        /* "2024 · Movie" */
        public string describe () {
            return year == "" ? type_label : "%s · %s".printf (year, type_label);
        }

        /* Show progress as a fraction, or -1 when there's nothing to show */
        public double progress_fraction {
            get {
                if (is_movie || aired_count == 0 || watched_count == 0) {
                    return -1;
                }
                return (double) watched_count / aired_count;
            }
        }

        public static Title? from_json (Json.Object o, MediaType? fallback = null) {
            MediaType type;
            if (!MediaType.try_parse (JsonUtil.str (o, "media_type"), out type)) {
                if (fallback == null) {
                    return null;
                }
                type = fallback;
            }
            var t = new Title (type, o.get_int_member_with_default ("id", 0));
            t.update_from_json (o);
            return t;
        }

        /**
         * Updates the metadata from a TMDB search result or details object.
         * Members missing from the object are left alone.
         */
        public void update_from_json (Json.Object o) {
            freeze_notify ();
            if (is_movie) {
                set_str (o, "title", (v) => name = v ?? "");
                set_str (o, "original_title", (v) => original_name = v);
                set_str (o, "release_date", (v) => release_date = v);
                if (o.has_member ("runtime")) {
                    runtime = (int) JsonUtil.integer (o, "runtime");
                }
            } else {
                set_str (o, "name", (v) => name = v ?? "");
                set_str (o, "original_name", (v) => original_name = v);
                set_str (o, "first_air_date", (v) => release_date = v);
                var run_times = JsonUtil.array (o, "episode_run_time");
                if (run_times != null) {
                    runtime = run_times.get_length () > 0 ? (int) run_times.get_int_element (0) : 0;
                }
                if (o.has_member ("created_by")) {
                    creators = JsonUtil.join_names (o, "created_by");
                }
                if (o.has_member ("networks")) {
                    networks = JsonUtil.join_names (o, "networks");
                }
                if (o.has_member ("number_of_seasons")) {
                    number_of_seasons = (int) JsonUtil.integer (o, "number_of_seasons");
                }
                if (o.has_member ("number_of_episodes")) {
                    number_of_episodes = (int) JsonUtil.integer (o, "number_of_episodes");
                }
            }
            set_str (o, "original_language", (v) => original_language = v);
            set_str (o, "overview", (v) => overview = v);
            set_str (o, "poster_path", (v) => poster_path = v);
            set_str (o, "backdrop_path", (v) => backdrop_path = v);
            set_str (o, "status", (v) => tmdb_status = v);
            if (o.has_member ("genres")) {
                genres = JsonUtil.join_names (o, "genres");
            }
            if (o.has_member ("vote_average")) {
                vote_average = JsonUtil.number (o, "vote_average");
            }
            thaw_notify ();
        }

        private delegate void StringSetter (string? value);

        private static void set_str (Json.Object o, string member, StringSetter setter) {
            if (o.has_member (member)) {
                var v = JsonUtil.str (o, member);
                setter (v == "" ? null : v);
            }
        }
    }
}
