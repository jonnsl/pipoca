namespace Pipoca {
    public class RadarrClient : ArrClient {
        public RadarrClient (string address, string? api_key, string? username, string? password,
                             bool accept_any_certificate) throws Error {
            base ("Radarr", address, api_key, username, password, accept_any_certificate);
        }

        public override async GenericArray<ArrItem> get_items (Cancellable? cancellable = null) throws Error {
            return parse_items (yield get_array ("/movie", cancellable));
        }

        /**
         * Adds a movie, monitored, without starting a search: Radarr picks up a
         * release through its regular RSS checks.
         */
        public async void add_movie (int64 tmdb_id, int64 quality_profile_id, string root_folder,
                                     Cancellable? cancellable = null) throws Error {
            // Radarr wants the whole movie resource, which its lookup gives us
            var movie = yield request ("GET", "/movie/lookup/tmdb?tmdbId=%lld".printf (tmdb_id), null, cancellable);
            if (movie.get_node_type () != Json.NodeType.OBJECT) {
                throw invalid_response ();
            }
            var o = movie.get_object ();
            o.set_int_member ("qualityProfileId", quality_profile_id);
            o.set_string_member ("rootFolderPath", root_folder);
            o.set_boolean_member ("monitored", true);
            o.set_string_member ("minimumAvailability", "released");
            var options = new Json.Object ();
            options.set_boolean_member ("searchForMovie", false);
            o.set_object_member ("addOptions", options);
            yield request ("POST", "/movie", movie, cancellable);
        }
    }
}
