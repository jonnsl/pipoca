namespace Aperture {
    /* A person in a title's cast or crew */
    public class Credit : Object {
        private const int MAX_CAST = 20;
        /* Crew jobs worth showing for movies; shows list their creators instead */
        private const string[] MOVIE_JOBS = { "Director", "Screenplay", "Writer" };

        public int64 person_id { get; construct; }
        public string name { get; construct; }
        /* Character or job */
        public string role { get; set; default = ""; }
        public string? profile_path { get; construct; }

        public Credit (int64 person_id, string name, string role, string? profile_path) {
            Object (person_id: person_id, name: name, role: role, profile_path: profile_path);
        }

        public string tmdb_url {
            owned get { return "https://www.themoviedb.org/person/%lld".printf (person_id); }
        }

        /**
         * The key crew, then the main cast, from TMDB details fetched with
         * append_to_response=credits (movies) or aggregate_credits (shows).
         */
        public static GenericArray<Credit> parse (Json.Object details, MediaType type) {
            var result = new GenericArray<Credit> ();
            var by_id = new HashTable<int64?, Credit> (int64_hash, int64_equal);
            if (type == MediaType.TV) {
                foreach (var o in objects (details, "created_by")) {
                    add_crew (result, by_id, o, _("Creator"));
                }
            } else {
                var credits = JsonUtil.object (details, "credits");
                if (credits != null) {
                    foreach (var o in objects (credits, "crew")) {
                        var job = JsonUtil.str (o, "job");
                        if (job in MOVIE_JOBS) {
                            add_crew (result, by_id, o, job_label (job));
                        }
                    }
                }
            }

            var credits = JsonUtil.object (details, type == MediaType.TV ? "aggregate_credits" : "credits");
            if (credits == null) {
                return result;
            }
            var cast = 0;
            foreach (var o in objects (credits, "cast")) {
                if (cast >= MAX_CAST) {
                    break;
                }
                string? character;
                if (type == MediaType.TV) {
                    // Shows list each role with its episode count; the first is the main one
                    var roles = objects (o, "roles");
                    character = roles.length > 0 ? JsonUtil.str (roles[0], "character") : null;
                } else {
                    character = JsonUtil.str (o, "character");
                }
                var c = make (o, character ?? "");
                if (c != null) {
                    result.add (c);
                    cast++;
                }
            }
            return result;
        }

        private static Credit? make (Json.Object o, string role) {
            var id = JsonUtil.integer (o, "id");
            var name = JsonUtil.str (o, "name");
            if (id <= 0 || name == null || name == "") {
                return null;
            }
            var profile = JsonUtil.str (o, "profile_path");
            return new Credit (id, name, role, profile == "" ? null : profile);
        }

        /* One entry per person, with all their jobs */
        private static void add_crew (GenericArray<Credit> result, HashTable<int64?, Credit> by_id,
                                      Json.Object o, string role) {
            var id = JsonUtil.integer (o, "id");
            var existing = by_id[id];
            if (existing != null) {
                if (!(role in existing.role.split (", "))) {
                    existing.role = "%s, %s".printf (existing.role, role);
                }
                return;
            }
            var c = make (o, role);
            if (c != null) {
                by_id[id] = c;
                result.add (c);
            }
        }

        /* TMDB only returns jobs in English */
        private static string job_label (string job) {
            switch (job) {
            case "Director":
                return _("Director");
            case "Screenplay":
                return _("Screenplay");
            case "Writer":
                return _("Writer");
            default:
                return job;
            }
        }

        private static GenericArray<Json.Object> objects (Json.Object o, string member) {
            var result = new GenericArray<Json.Object> ();
            var arr = JsonUtil.array (o, member);
            if (arr != null) {
                arr.foreach_element ((a, i, node) => {
                    if (node.get_node_type () == Json.NodeType.OBJECT) {
                        result.add (node.get_object ());
                    }
                });
            }
            return result;
        }
    }
}
