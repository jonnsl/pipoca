namespace Pipoca {
    /* Syncs movies with Radarr; see ArrImport for the rules */
    public class RadarrSync : ArrSync {
        private static RadarrSync? instance;

        private RadarrSync () {
            Object (service: "Radarr", media_type: MediaType.MOVIE);
        }

        public static RadarrSync get_default () {
            if (instance == null) {
                instance = new RadarrSync ();
            }
            return instance;
        }

        protected override ArrClient create_client (string address, string? api_key, string? username,
                                                    string? password, bool accept_any_certificate) throws Error {
            return new RadarrClient (address, api_key, username, password, accept_any_certificate);
        }

        protected override async void add (ArrClient client, Library library, Title title, int64 profile,
                                           string folder, Cancellable? cancellable) throws Error {
            yield ((RadarrClient) client).add_movie (title.id, profile, folder, cancellable);
        }
    }
}
