namespace Aperture.Utils {
    /* Today's local date as "YYYY-MM-DD", the format TMDB uses */
    public string today () {
        return new DateTime.now_local ().format ("%F");
    }

    /* The local date @days from today as "YYYY-MM-DD" */
    public string days_from_today (int days) {
        return new DateTime.now_local ().add_days (days).format ("%F");
    }

    public DateTime? parse_date (string? date) {
        if (date == null || date.length < 10) {
            return null;
        }
        return new DateTime.from_iso8601 (date.substring (0, 10) + "T00:00:00", new TimeZone.local ());
    }

    /* "Jan 17, 2025" */
    public string format_date (string? date) {
        var dt = parse_date (date);
        if (dt == null) {
            return "";
        }
        // Translators: date format, see https://docs.gtk.org/glib/method.DateTime.format.html
        // xgettext:no-c-format
        return dt.format (_("%b %-d, %Y"));
    }

    /* "Fri, Oct 24" for dates within the next months */
    public string format_upcoming_date (string? date) {
        var dt = parse_date (date);
        if (dt == null) {
            return "";
        }
        var now = new DateTime.now_local ();
        if (dt.get_year () == now.get_year ()) {
            // Translators: date format, see https://docs.gtk.org/glib/method.DateTime.format.html
            // xgettext:no-c-format
            return dt.format (_("%a, %b %-d"));
        }
        return format_date (date);
    }

    public string format_runtime (int minutes) {
        if (minutes <= 0) {
            return "";
        }
        if (minutes < 60) {
            return _("%d min").printf (minutes);
        }
        if (minutes % 60 == 0) {
            return _("%d h").printf (minutes / 60);
        }
        return _("%d h %d min").printf (minutes / 60, minutes % 60);
    }

    /* TMDB only returns statuses in English */
    public string? tmdb_status_label (string? status) {
        switch (status) {
        case "Returning Series":
            return _("Returning Series");
        case "Ended":
            return _("Ended");
        case "Canceled":
            return _("Canceled");
        case "In Production":
            return _("In Production");
        case "Planned":
            return _("Planned");
        case "Pilot":
            return _("Pilot");
        case "Rumored":
            return _("Rumored");
        case "Post Production":
            return _("Post Production");
        case "Released":
            return _("Released");
        default:
            return status;
        }
    }

    /* The ISO 639-1 codes TMDB titles commonly use */
    private HashTable<string, string>? languages = null;

    private unowned HashTable<string, string> get_languages () {
        if (languages == null) {
            languages = new HashTable<string, string> (str_hash, str_equal);
            string[] pairs = {
                "ar", "Arabic", "bn", "Bengali", "ca", "Catalan", "cn", "Chinese", "cs", "Czech",
                "da", "Danish", "de", "German", "el", "Greek", "en", "English", "es", "Spanish",
                "et", "Estonian", "fa", "Persian", "fi", "Finnish", "fr", "French", "he", "Hebrew",
                "hi", "Hindi", "hu", "Hungarian", "id", "Indonesian", "is", "Icelandic", "it", "Italian",
                "ja", "Japanese", "ko", "Korean", "ml", "Malayalam", "ms", "Malay", "nl", "Dutch",
                "no", "Norwegian", "pl", "Polish", "pt", "Portuguese", "ro", "Romanian", "ru", "Russian",
                "sk", "Slovak", "sr", "Serbian", "sv", "Swedish", "ta", "Tamil", "te", "Telugu",
                "th", "Thai", "tl", "Tagalog", "tr", "Turkish", "uk", "Ukrainian", "vi", "Vietnamese",
                "zh", "Chinese",
            };
            for (var i = 0; i + 1 < pairs.length; i += 2) {
                languages[pairs[i]] = pairs[i + 1];
            }
        }
        return languages;
    }

    public string language_name (string? code) {
        if (code == null || code == "") {
            return "";
        }
        var english = get_languages ()[code];
        if (english == null) {
            return code;
        }
        // iso-codes translates the English names
        return dgettext ("iso_639", english);
    }

    /* Joins the non-empty strings with " · " */
    public string join_dot (string?[] parts) {
        var b = new StringBuilder ();
        foreach (var p in parts) {
            if (p == null || p == "") {
                continue;
            }
            if (b.len > 0) {
                b.append (" · ");
            }
            b.append (p);
        }
        return b.str;
    }
}

namespace Aperture.JsonUtil {
    /* Null-safe accessors for TMDB's JSON, where most members can be null */

    public string? str (global::Json.Object o, string member) {
        var node = o.get_member (member);
        if (node == null || node.get_node_type () != global::Json.NodeType.VALUE) {
            return null;
        }
        return node.get_value_type () == typeof (string) ? node.get_string () : null;
    }

    public int64 integer (global::Json.Object o, string member) {
        var node = o.get_member (member);
        if (node == null || node.get_node_type () != global::Json.NodeType.VALUE) {
            return 0;
        }
        var type = node.get_value_type ();
        if (type == typeof (int64)) {
            return node.get_int ();
        }
        if (type == typeof (double)) {
            return (int64) node.get_double ();
        }
        return 0;
    }

    public double number (global::Json.Object o, string member) {
        var node = o.get_member (member);
        if (node == null || node.get_node_type () != global::Json.NodeType.VALUE) {
            return 0;
        }
        var type = node.get_value_type ();
        if (type == typeof (double)) {
            return node.get_double ();
        }
        if (type == typeof (int64)) {
            return node.get_int ();
        }
        return 0;
    }

    public unowned global::Json.Array? array (global::Json.Object o, string member) {
        var node = o.get_member (member);
        if (node == null || node.get_node_type () != global::Json.NodeType.ARRAY) {
            return null;
        }
        return node.get_array ();
    }

    public unowned global::Json.Object? object (global::Json.Object o, string member) {
        var node = o.get_member (member);
        if (node == null || node.get_node_type () != global::Json.NodeType.OBJECT) {
            return null;
        }
        return node.get_object ();
    }

    /* Joins the "name" member of an array of objects, e.g. genres */
    public string? join_names (global::Json.Object o, string member) {
        var arr = array (o, member);
        if (arr == null) {
            return null;
        }
        string[] names = {};
        arr.foreach_element ((a, i, node) => {
            if (node.get_node_type () == global::Json.NodeType.OBJECT) {
                var name = str (node.get_object (), "name");
                if (name != null && name != "") {
                    names += name;
                }
            }
        });
        return names.length > 0 ? string.joinv (", ", names) : null;
    }
}
