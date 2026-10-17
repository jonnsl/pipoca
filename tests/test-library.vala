using Aperture;

/* Status and progress derivation, against a temporary database (see tests/meson.build) */

Episode ep (int64 show_id, int season, int number, string air_date) {
    var e = new Episode (show_id, season, number);
    e.name = "Episode %d".printf (number);
    e.air_date = air_date;
    return e;
}

Title make_show (int64 id, string status) {
    var lib = Library.get_default ();
    var t = new Title (MediaType.TV, id);
    t.name = "Show %lld".printf (id);
    t.tmdb_status = status;
    // Pretend it's fresh so add() doesn't hit the network
    t.refreshed_at = new DateTime.now_utc ().to_unix ();
    var seasons = new GenericArray<Season> ();
    seasons.add (new Season (id, 0));
    seasons.add (new Season (id, 1));
    seasons.add (new Season (id, 2));
    var specials = new GenericArray<Episode> ();
    specials.add (ep (id, 0, 1, "2019-01-01"));
    var s1 = new GenericArray<Episode> ();
    s1.add (ep (id, 1, 1, "2020-01-01"));
    s1.add (ep (id, 1, 2, "2020-01-08"));
    s1.add (ep (id, 1, 3, "2020-01-15"));
    var s2 = new GenericArray<Episode> ();
    s2.add (ep (id, 2, 1, "2021-01-01"));
    s2.add (ep (id, 2, 2, "2099-01-01"));
    try {
        lib.db.save_seasons (id, seasons);
        lib.db.save_episodes (id, 0, specials);
        lib.db.save_episodes (id, 1, s1);
        lib.db.save_episodes (id, 2, s2);
    } catch (Error e) {
        error (e.message);
    }
    return lib.intern (t);
}

void test_show_progress () {
    var lib = Library.get_default ();
    var show = make_show (100, "Returning Series");
    lib.add (show);
    assert (show.in_library);
    assert (show.status == TitleStatus.PLAN_TO_WATCH);
    assert (show.aired_count == 4);
    assert (show.total_count == 5);
    assert (show.next_episode.season_number == 1 && show.next_episode.episode_number == 1);
    assert (show.upcoming_episode.season_number == 2 && show.upcoming_episode.episode_number == 2);

    var s1 = lib.get_episodes (show, 1);
    var first = new GenericArray<Episode> ();
    first.add (s1[0]);
    lib.set_episodes_watched (show, first, true);
    assert (show.status == TitleStatus.WATCHING);
    assert (show.watched_count == 1);
    assert (show.next_episode.episode_number == 2);

    // Specials don't count towards progress
    lib.set_episodes_watched (show, lib.get_episodes (show, 0), true);
    assert (show.watched_count == 1);

    // Up to S2E1 marks the earlier regular episodes too, but not the unaired one
    var s2 = lib.get_episodes (show, 2);
    var changed = lib.set_episodes_watched (show, lib.get_episodes_up_to (show, s2[0]), true);
    assert (changed.length == 3);
    assert (show.status == TitleStatus.UP_TO_DATE);
    assert (show.next_episode == null);

    // Unwatching one goes back to Watching, and it becomes the next episode
    var one = new GenericArray<Episode> ();
    one.add (lib.get_episodes (show, 1)[1]);
    lib.set_episodes_watched (show, one, false);
    assert (show.status == TitleStatus.WATCHING);
    assert (show.next_episode.season_number == 1 && show.next_episode.episode_number == 2);

    var seasons = lib.get_seasons (show);
    assert (seasons[0].season_number == 1);  // specials last
    assert (seasons[0].aired_count == 3 && seasons[0].watched_count == 2);
    assert (seasons[2].season_number == 0);
}

void test_ended_show () {
    var lib = Library.get_default ();
    var show = make_show (200, "Ended");
    lib.add (show);
    var all = new GenericArray<Episode> ();
    foreach (var s in new int[] { 1, 2 }) {
        foreach (var e in lib.get_episodes (show, s)) {
            all.add (e);
        }
    }
    lib.set_episodes_watched (show, all, true);
    // The 2099 episode can't be watched, so the show is only up to date
    assert (show.status == TitleStatus.UP_TO_DATE);

    // Once every episode has aired and been watched, an ended show is done
    var s2 = lib.get_episodes (show, 2);
    s2[1].air_date = "2021-01-08";
    try {
        lib.db.save_episodes (show.id, 2, s2);
    } catch (Error e) {
        error (e.message);
    }
    var last = new GenericArray<Episode> ();
    last.add (lib.get_episodes (show, 2)[1]);
    lib.set_episodes_watched (show, last, true);
    assert (show.status == TitleStatus.WATCHED);
    assert (show.status.is_done ());
}

void test_movie () {
    var lib = Library.get_default ();
    var movie = new Title (MediaType.MOVIE, 300);
    movie.name = "A Movie";
    movie.refreshed_at = new DateTime.now_utc ().to_unix ();
    movie = lib.intern (movie);

    // Watching something that isn't in the library adds it
    lib.set_movie_watched (movie, true);
    assert (movie.in_library);
    assert (movie.status == TitleStatus.WATCHED);
    assert (movie.last_watched_at > 0);

    lib.set_movie_watched (movie, false);
    assert (movie.status == TitleStatus.PLAN_TO_WATCH);

    var before = lib.titles.get_n_items ();
    lib.remove (movie);
    assert (!movie.in_library);
    assert (movie.status == TitleStatus.NONE);
    assert (lib.titles.get_n_items () == before - 1);

    lib.add (movie);
    assert (movie.in_library && lib.titles.get_n_items () == before);
}

void test_persistence () {
    var path = Path.build_filename (Environment.get_user_data_dir (), "aperture", "library.db");
    try {
        var db = new Database (path);
        var titles = db.load_library ();
        assert (titles.length == 3);
        var show = db.load_title (MediaType.TV, 100);
        assert (show.name == "Show 100" && show.in_library);
    } catch (Error e) {
        error (e.message);
    }
}

void test_from_json () {
    var parser = new Json.Parser ();
    try {
        parser.load_from_data ("""{"media_type": "tv", "id": 95396, "name": "Severance",
            "first_air_date": "2022-02-17", "poster_path": null, "vote_average": 8.4,
            "genres": [{"id": 18, "name": "Drama"}, {"id": 9648, "name": "Mystery"}],
            "episode_run_time": [], "networks": [{"name": "Apple TV+"}]}""");
    } catch (Error e) {
        error (e.message);
    }
    var t = Title.from_json (parser.get_root ().get_object ());
    assert (t.media_type == MediaType.TV && t.id == 95396);
    assert (t.name == "Severance" && t.year == "2022");
    assert (t.poster_path == null);
    assert (t.genres == "Drama, Mystery" && t.networks == "Apple TV+");
    assert (t.describe () == "2022 · TV Show");

    try {
        parser.load_from_data ("""{"media_type": "person", "id": 1}""");
    } catch (Error e) {
        error (e.message);
    }
    assert (Title.from_json (parser.get_root ().get_object ()) == null);
}

Json.Object parse_object (string data) {
    var parser = new Json.Parser ();
    try {
        parser.load_from_data (data);
    } catch (Error e) {
        error (e.message);
    }
    return parser.get_root ().get_object ();
}

void test_export () {
    var lib = Library.get_default ();
    string data;
    try {
        data = LibraryTransfer.export_json (lib);
    } catch (Error e) {
        error (e.message);
    }
    var root = parse_object (data);
    assert (root.get_string_member ("format") == "aperture-library");
    assert (root.get_int_member ("version") == 1);
    var titles = root.get_array_member ("titles");
    assert (titles.get_length () == lib.titles.get_n_items ());

    Json.Object? show = null;
    for (uint i = 0; i < titles.get_length (); i++) {
        var t = titles.get_object_element (i);
        if (t.get_string_member ("media_type") == "tv" && t.get_int_member ("tmdb_id") == 100) {
            show = t;
        }
    }
    assert (show != null);
    assert (show.get_string_member ("name") == "Show 100");
    var watched = show.get_array_member ("watched");
    // S1E1, S0E1 (specials), S1E3, S2E1 from test_show_progress
    assert (watched.get_length () == 4);
    var first = watched.get_object_element (0);
    assert (first.has_member ("season") && first.has_member ("episode") && first.has_member ("watched_at"));
    assert (new DateTime.from_iso8601 (first.get_string_member ("watched_at"), null) != null);

    // Importing our own export changes nothing
    try {
        var result = LibraryTransfer.import_json (lib, data);
        assert (result.titles_added == 0 && result.events_added == 0 && result.titles_skipped == 0);
    } catch (Error e) {
        error (e.message);
    }

    // Removed titles come back with their original date
    var movie = lib.lookup (MediaType.MOVIE, 300);
    var added_at = movie.added_at;
    lib.remove (movie);
    try {
        var result = LibraryTransfer.import_json (lib, data);
        assert (result.titles_added == 1);
    } catch (Error e) {
        error (e.message);
    }
    assert (movie.in_library && movie.added_at == added_at);
}

void test_import () {
    var lib = Library.get_default ();
    var data = """{
        "format": "aperture-library",
        "version": 1,
        "titles": [
            {"media_type": "movie", "tmdb_id": 400, "name": "Imported Movie", "release_date": "1999-03-31",
             "added_at": "2024-01-02T03:04:05Z", "watched": [{"watched_at": "2024-02-01T20:00:00Z"}]},
            {"media_type": "tv", "tmdb_id": 100, "name": "Show 100",
             "watched": [{"season": 1, "episode": 2, "watched_at": "2024-03-01T20:00:00Z"},
                         {"season": 1, "episode": 2, "watched_at": "2024-03-01T20:00:00Z"},
                         {"episode": 3, "watched_at": "2024-03-01T20:00:00Z"},
                         {"season": 1, "episode": 3}]},
            {"media_type": "person", "tmdb_id": 1},
            {"media_type": "movie", "tmdb_id": -5},
            "garbage"
        ]
    }""";
    ImportResult result;
    try {
        result = LibraryTransfer.import_json (lib, data);
    } catch (Error e) {
        error (e.message);
    }
    assert (result.titles_added == 1);
    assert (result.titles_skipped == 3);
    // The movie's event plus one S1E2 event; the duplicate and malformed ones are dropped
    assert (result.events_added == 2);

    var movie = lib.lookup (MediaType.MOVIE, 400);
    assert (movie.in_library && movie.name == "Imported Movie" && movie.year == "1999");
    assert (movie.added_at == new DateTime.utc (2024, 1, 2, 3, 4, 5).to_unix ());
    assert (movie.status == TitleStatus.WATCHED);
    assert (!movie.has_details);

    // S1E2 was the only aired episode left, so the show is caught up
    var show = lib.lookup (MediaType.TV, 100);
    assert (lib.get_episodes (show, 1)[1].watched);
    assert (show.watched_count == show.aired_count);
    assert (show.status == TitleStatus.UP_TO_DATE);
}

void test_import_errors () {
    var lib = Library.get_default ();
    string[] bad = {
        "not json",
        "[]",
        """{"format": "something-else", "version": 1, "titles": []}""",
        """{"format": "aperture-library", "version": 1}""",
    };
    foreach (var data in bad) {
        try {
            LibraryTransfer.import_json (lib, data);
            assert_not_reached ();
        } catch (Error e) {
            // Expected
        }
    }
    try {
        LibraryTransfer.import_json (lib, """{"format": "aperture-library", "version": 99, "titles": []}""");
        assert_not_reached ();
    } catch (TransferError.UNSUPPORTED_VERSION e) {
        // Expected
    } catch (Error e) {
        assert_not_reached ();
    }
}

int main (string[] args) {
    Test.init (ref args);
    // Start from an empty database
    var path = Path.build_filename (Environment.get_user_data_dir (), "aperture", "library.db");
    foreach (var suffix in new string[] { "", "-wal", "-shm" }) {
        FileUtils.remove (path + suffix);
    }
    Test.add_func ("/title/from-json", test_from_json);
    Test.add_func ("/library/show-progress", test_show_progress);
    Test.add_func ("/library/ended-show", test_ended_show);
    Test.add_func ("/library/movie", test_movie);
    Test.add_func ("/library/persistence", test_persistence);
    Test.add_func ("/transfer/export", test_export);
    Test.add_func ("/transfer/import", test_import);
    Test.add_func ("/transfer/import-errors", test_import_errors);
    return Test.run ();
}
