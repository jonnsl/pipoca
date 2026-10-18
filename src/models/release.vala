namespace Pipoca {
    /* A movie release or an episode airing on a given date */
    public class Release : Object {
        public Title title { get; construct; }
        /* Null for movies */
        public Episode? episode { get; construct; }

        public Release (Title title, Episode? episode = null) {
            Object (title: title, episode: episode);
        }

        /* "YYYY-MM-DD" */
        public string date {
            get { return episode != null ? episode.air_date : title.release_date; }
        }
    }
}
