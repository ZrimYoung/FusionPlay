//! Resolve presentation metadata and track continuity from sender-supplied MiPlay events.
use serde_json::Value;

const MAX_LYRICS: usize = 256 * 1024;
const MAX_LABEL: usize = 512;

#[derive(Default)]
pub(super) struct TrackMetadata {
    id: String,
    id_source: String,
    explicit_id: Option<String>,
    title: String,
    title_verified: bool,
    artist: String,
    album: String,
    display_artist: Option<String>,
    display_album: Option<String>,
    duration: Option<u64>,
    position: Option<u64>,
    lyrics: Lyrics,
}

impl TrackMetadata {
    pub(super) fn observe_position(&mut self, millis: u64) {
        self.position = Some(millis);
    }

    pub(super) fn apply(&mut self, event: &mut Value) {
        let packet_id = text(event, "track_id");
        let packet_source = text(event, "track_id_source");
        let explicit = (packet_source == "explicit" && !packet_id.is_empty()).then_some(packet_id);
        let raw_title = raw(event, "raw_title", "title");
        let artist = raw(event, "raw_artist", "artist");
        let album = raw(event, "raw_album", "album");
        let duration = event["duration_ms"].as_u64().filter(|ms| *ms > 0);
        let position = event["position_ms"].as_u64();
        let document = text(event, "lyrics_text");
        let same_document = !document.is_empty() && document == self.lyrics.source;
        let incoming = (!document.is_empty() && !same_document).then(|| Lyrics::parse(document));
        let incoming_name = incoming.as_ref().and_then(Lyrics::song_title);
        let same_title = !raw_title.is_empty() && equivalent(raw_title, &self.title);
        let same_header = incoming_name.is_some_and(|name| equivalent(name, &self.title));
        let provisional_title = if raw_title.is_empty() {
            &self.title
        } else {
            raw_title
        };
        let late_document = self.lyrics.source.is_empty()
            && !self.title_verified
            && incoming.as_ref().is_some_and(|lyrics| {
                lyrics
                    .song_title()
                    .is_some_and(|title| !equivalent(title, provisional_title))
                    && lyrics.matches_caption(provisional_title, position.or(self.position))
            });
        let metadata_agrees = compatible(album, &self.album)
            && (compatible(artist, &self.artist)
                || self
                    .display_artist
                    .as_ref()
                    .is_some_and(|known| equivalent(artist, known))
                || composite_artist(artist, &self.title, "").is_some_and(|tail| {
                    equivalent(tail, &self.artist)
                        || self
                            .display_artist
                            .as_ref()
                            .is_some_and(|known| equivalent(tail, known))
                }))
            && duration
                .zip(self.duration)
                .is_none_or(|(new, old)| new.abs_diff(old) <= 2_000);
        // When both sides have explicit IDs they are authoritative. With
        // inferred IDs, a metadata-only update does not begin a new song.
        let same = !self.id.is_empty()
            && match (explicit, self.explicit_id.as_deref()) {
                (Some(new), Some(old)) => new == old,
                (Some(_), None) => metadata_agrees && (same_title || same_document || same_header),
                (None, _) => {
                    metadata_agrees
                        && (same_title
                            || same_document
                            || same_header
                            || late_document
                            || (incoming.is_none()
                                && self
                                    .lyrics
                                    .matches_caption(raw_title, position.or(self.position))))
                        || (raw_title.is_empty() && incoming.is_none())
                }
            };
        if !same && !packet_id.is_empty() {
            *self = Self {
                id: packet_id.to_owned(),
                id_source: packet_source.to_owned(),
                ..Self::default()
            };
        }
        if let Some(value) = explicit {
            self.explicit_id = Some(value.to_owned());
        }
        if let Some(lyrics) = incoming {
            self.lyrics = lyrics;
        }
        if let Some(value) = position {
            self.observe_position(value);
        }
        if let Some(value) = duration {
            self.duration = Some(value);
        }

        let lyrics = &self.lyrics;
        let header = lyrics.song_title();
        let known_album = lyrics.album.value.as_deref().unwrap_or(album);
        let composite = recover_composite(
            artist,
            header,
            lyrics.artist.value.as_deref(),
            album,
            known_album,
        );
        let candidate = header.or_else(|| composite.as_ref().map(|(name, _)| name.as_str()));
        let agrees_with_title = !raw_title.is_empty()
            && (candidate.is_some_and(|title| equivalent(raw_title, title))
                || (self.title_verified && equivalent(raw_title, &self.title)));
        let caption = !agrees_with_title
            && (event["title_is_lyric"].as_bool().unwrap_or(false)
                || lyrics.matches_caption(raw_title, position.or(self.position)));
        if let Some(title) =
            candidate.filter(|_| raw_title.is_empty() || caption || agrees_with_title)
        {
            self.title = title.to_owned();
            self.title_verified = true;
        } else if self.title.is_empty() && !caption && !raw_title.is_empty() {
            self.title = raw_title.to_owned();
        }

        if let Some((_, performer)) = composite.filter(|(song, _)| equivalent(song, &self.title)) {
            self.display_artist = Some(performer);
        } else if self.display_artist.is_none() && (caption || artist.is_empty()) {
            self.display_artist = lyrics.artist.value.clone();
        }
        if self.display_album.is_none() && (caption || album.is_empty()) {
            self.display_album = lyrics.album.value.clone();
        }
        if !artist.is_empty() && (!caption || self.artist.is_empty()) {
            self.artist = artist.to_owned();
        }
        if !album.is_empty() {
            self.album = album.to_owned();
        }

        if !self.id.is_empty() {
            event["track_id"] = self.id.clone().into();
            event["track_id_source"] = self.id_source.clone().into();
            event["track_transition"] = if same { "same" } else { "new" }.into();
        }
        if !self.title.is_empty() || caption {
            event["display_title"] = self.title.clone().into();
        }
        if let Some(artist) = &self.display_artist {
            event["display_artist"] = artist.clone().into();
        }
        if let Some(album) = &self.display_album {
            event["display_album"] = album.clone().into();
        }
        event["title_is_lyric"] = caption.into();
    }
}

fn text<'a>(event: &'a Value, key: &str) -> &'a str {
    event[key].as_str().unwrap_or("").trim()
}

fn raw<'a>(event: &'a Value, raw_key: &str, legacy_key: &str) -> &'a str {
    event[raw_key]
        .as_str()
        .map(str::trim)
        .unwrap_or_else(|| text(event, legacy_key))
}

fn normalized(text: &str) -> String {
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .replace('’', "'")
        .to_lowercase()
}

fn equivalent(first: &str, second: &str) -> bool {
    normalized(first) == normalized(second)
}

fn compatible(first: &str, second: &str) -> bool {
    first.is_empty() || second.is_empty() || equivalent(first, second)
}

fn is_dash(c: char) -> bool {
    matches!(c, '-' | '–' | '—')
}

fn strip_suffix<'a>(source: &'a str, expected: &str) -> Option<&'a str> {
    if expected.is_empty() {
        return None;
    }
    source
        .match_indices(is_dash)
        .rev()
        .find_map(|(dash, value)| {
            let trailing = source[dash + value.len()..].trim();
            let leading = source[..dash].trim();
            (!leading.is_empty() && equivalent(trailing, expected)).then_some(leading)
        })
}

fn composite_artist<'a>(
    source: &'a str,
    expected_title: &str,
    known_album: &str,
) -> Option<&'a str> {
    if expected_title.is_empty() {
        return None;
    }
    let source = strip_suffix(source, known_album).unwrap_or(source);
    source.match_indices(is_dash).find_map(|(dash, value)| {
        let leading = source[..dash].trim();
        let trailing = source[dash + value.len()..].trim();
        (!trailing.is_empty() && equivalent(leading, expected_title)).then_some(trailing)
    })
}

fn recover_composite(
    source: &str,
    title: Option<&str>,
    artist: Option<&str>,
    album: &str,
    header_album: &str,
) -> Option<(String, String)> {
    let variants = [
        Some(source),
        strip_suffix(source, album),
        strip_suffix(source, header_album),
    ];
    let mut result: Option<(&str, &str)> = None;
    for variant in variants.into_iter().flatten() {
        let inferred = match (title, artist) {
            (Some(title), artist) => composite_artist(variant, title, "")
                .filter(|performer| artist.is_none_or(|expected| equivalent(performer, expected)))
                .map(|performer| (title, artist.unwrap_or(performer))),
            (None, Some(performer)) => {
                strip_suffix(variant, performer).map(|name| (name, performer))
            }
            _ => None,
        };
        if let Some((name, performer)) = inferred {
            if result.is_some_and(|(old_name, old_artist)| {
                !equivalent(name, old_name) || !equivalent(performer, old_artist)
            }) {
                return None;
            }
            result = Some((name, performer));
        }
    }
    result.map(|(name, performer)| (name.to_owned(), performer.to_owned()))
}

#[derive(Default)]
struct Header {
    value: Option<String>,
    conflicted: bool,
}

impl Header {
    fn observe(&mut self, value: &str) {
        let value = value.trim();
        if self.conflicted
            || value.is_empty()
            || value.len() > MAX_LABEL
            || value.chars().any(char::is_control)
        {
            return;
        }
        if self
            .value
            .as_ref()
            .is_some_and(|previous| !equivalent(previous, value))
        {
            self.conflicted = true;
            self.value = None;
        } else if self.value.is_none() {
            self.value = Some(value.to_owned());
        }
    }
}

#[derive(Default)]
struct Lyrics {
    source: String,
    title: Header,
    artist: Header,
    album: Header,
    timed: Vec<(u64, String)>,
}

impl Lyrics {
    fn parse(source: &str) -> Self {
        if source.len() > MAX_LYRICS {
            return Self::default();
        }
        let mut result = Self {
            source: source.to_owned(),
            ..Self::default()
        };
        let mut offset = 0_i64;
        for line in source.lines() {
            let mut row = line.trim().trim_start_matches('\u{feff}');
            let mut timestamps = Vec::new();
            while let Some((tag, body)) =
                row.strip_prefix('[').and_then(|rest| rest.split_once(']'))
            {
                if let Some(time) = timestamp(tag) {
                    timestamps.push(time);
                } else if timestamps.is_empty() {
                    if let Some((key, value)) = tag.split_once(':') {
                        match key.trim().to_ascii_lowercase().as_str() {
                            "ti" => result.title.observe(value),
                            "ar" => result.artist.observe(value),
                            "al" => result.album.observe(value),
                            "offset" => offset = value.trim().parse().unwrap_or(offset),
                            _ => break,
                        }
                    } else {
                        break;
                    }
                } else {
                    break;
                }
                row = body.trim_start();
            }
            if !timestamps.is_empty() {
                let row = normalized(&without_word_timestamps(row));
                for time in timestamps {
                    result.timed.push((time, row.clone()));
                }
            }
        }
        for (time, _) in &mut result.timed {
            *time = time.saturating_add_signed(offset);
        }
        result.timed.sort_by_key(|(time, _)| *time);
        result
    }

    fn song_title(&self) -> Option<&str> {
        self.title.value.as_deref()
    }

    fn matches_caption(&self, title: &str, position: Option<u64>) -> bool {
        if title.is_empty() || title.len() > MAX_LABEL {
            return false;
        }
        let needle = normalized(title);
        if needle.is_empty() {
            return false;
        }
        let substantial = needle.split_whitespace().count() >= 2
            || needle.chars().filter(|c| is_cjk(*c)).count() >= 4;
        let exact = self.timed.iter().any(|(_, row)| row == &needle);
        if exact
            || substantial
                && self
                    .timed
                    .iter()
                    .any(|(_, row)| contains_words(row, &needle))
        {
            return true;
        }
        // Only consider a short fragment when we know the playback position
        // and can match the active line (or the adjacent line at its boundary).
        let Some(position) = position else {
            return false;
        };
        let upper = self
            .timed
            .partition_point(|(time, _)| *time <= position.saturating_add(700));
        let current = self
            .timed
            .partition_point(|(time, _)| *time <= position.saturating_sub(700));
        let lower = if let Some((time, _)) = self.timed.get(current.saturating_sub(1)) {
            self.timed.partition_point(|(before, _)| before < time)
        } else {
            0
        };
        self.timed[lower..upper]
            .iter()
            .any(|(_, row)| contains_words(row, &needle))
    }
}

fn timestamp(tag: &str) -> Option<u64> {
    let (minutes, seconds) = tag.split_once(':')?;
    let minutes = minutes.parse::<u64>().ok()?;
    let seconds = seconds.parse::<f64>().ok()?;
    if !(0.0..60.0).contains(&seconds) {
        return None;
    }
    minutes
        .checked_mul(60_000)?
        .checked_add((seconds * 1_000.0).round() as u64)
}

fn without_word_timestamps(mut row: &str) -> String {
    let mut result = String::new();
    while let Some((before, rest)) = row.split_once('<') {
        result.push_str(before);
        if let Some((tag, body)) = rest
            .split_once('>')
            .filter(|(tag, _)| timestamp(tag).is_some())
        {
            let _ = tag;
            row = body;
        } else {
            result.push('<');
            row = rest;
        }
    }
    result.push_str(row);
    result
}

fn is_cjk(c: char) -> bool {
    matches!(c as u32, 0x3400..=0x9fff | 0xf900..=0xfaff | 0x20000..=0x323af | 0x3040..=0x31ff | 0xac00..=0xd7af)
}

fn word_char(c: char) -> bool {
    (c.is_alphanumeric() || matches!(c, '_' | '-' | '\'')) && !is_cjk(c)
}

fn contains_words(row: &str, needle: &str) -> bool {
    row.match_indices(needle).any(|(start, _)| {
        let end = start + needle.len();
        let left = needle.chars().next().is_some_and(word_char)
            && row[..start].chars().next_back().is_some_and(word_char);
        let right = needle.chars().next_back().is_some_and(word_char)
            && row[end..].chars().next().is_some_and(word_char);
        !left && !right
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const LYRICS: &str = "[ti:Night Walk][ar:Example Artist]\n[00:10.00]<00:10.00>Now we are going <00:11.00>home\n[00:42.00]Another row";
    fn packet(id: &str, source: &str, title: &str, lyrics: &str, position: Option<u64>) -> Value {
        json!({"event":"media_info","track_id":id,"track_id_source":source,"raw_title":title,
            "title":title,"raw_artist":"Example Artist","raw_album":"Record","lyrics_text":lyrics,"position_ms":position})
    }

    #[test]
    fn short_caption_keeps_identity_then_explicit_single_word_song_wins() {
        let mut track = TrackMetadata::default();
        let mut first = packet(
            "initial",
            "lyrics_metadata",
            "going home",
            LYRICS,
            Some(10_000),
        );
        track.apply(&mut first);
        assert_eq!(first["display_title"], "Night Walk");

        let mut word = packet("unstable-word-hash", "metadata", "home", "", Some(11_000));
        track.apply(&mut word);
        assert_eq!(word["title"], "home");
        assert_eq!(word["track_id"], "initial");
        assert_eq!(word["track_transition"], "same");
        assert_eq!(word["display_title"], "Night Walk");

        let mut partial = packet("artist-hash", "metadata", "", "", None);
        track.apply(&mut partial);
        assert_eq!(partial["track_id"], "initial");
        assert_eq!(partial["display_title"], "Night Walk");

        let mut next = packet(
            "explicit-next",
            "explicit",
            "Home",
            "[ti:Home]\n[00:00]Home",
            Some(0),
        );
        track.apply(&mut next);
        assert_eq!(next["track_transition"], "new");
        assert_eq!(next["track_id"], "explicit-next");
        assert_eq!(next["display_title"], "Home");
    }

    #[test]
    fn late_id_preserves_existing_public_identity_and_far_word_is_not_a_caption() {
        let mut track = TrackMetadata::default();
        track.apply(&mut packet(
            "inferred",
            "metadata",
            "Night Walk",
            LYRICS,
            Some(35_000),
        ));
        let mut late_id = packet("explicit", "explicit", "Night Walk", "", Some(42_000));
        track.apply(&mut late_id);
        assert_eq!(late_id["track_id"], "inferred");
        track.observe_position(44_000);
        let mut next = packet("other", "metadata", "Home", "", Some(0));
        track.apply(&mut next);
        assert_eq!(next["track_id"], "other");
        assert_eq!(next["title_is_lyric"], false);
        assert_eq!(next["display_title"], "Home");
    }

    #[test]
    fn late_lyrics_correct_the_first_unverified_title() {
        let mut track = TrackMetadata::default();
        track.apply(&mut packet(
            "word-hash",
            "metadata",
            "home",
            "",
            Some(11_000),
        ));
        let mut late = packet(
            "lyrics-hash",
            "lyrics_metadata",
            "home",
            LYRICS,
            Some(11_100),
        );
        track.apply(&mut late);
        assert_eq!(late["track_transition"], "same");
        assert_eq!(late["track_id"], "word-hash");
        assert_eq!(late["display_title"], "Night Walk");
    }

    #[test]
    fn new_explicit_id_is_not_inferred_from_a_cached_caption() {
        let mut track = TrackMetadata::default();
        track.apply(&mut packet(
            "inferred",
            "metadata",
            "Night Walk",
            LYRICS,
            Some(10_000),
        ));
        let mut next = packet("next", "explicit", "Home", "", Some(11_000));
        track.apply(&mut next);
        assert_eq!(next["track_transition"], "new");
        assert_eq!(next["track_id"], "next");
        assert_eq!(next["display_title"], "Home");
    }

    #[test]
    fn repairs_verified_composite_and_reports_missing_caption_title() {
        let mut composite = packet(
            "id",
            "explicit",
            "home",
            "[ar:Artist-With-Hyphens]\n[00:10]we are going home",
            Some(11_000),
        );
        composite["raw_artist"] = "Title-With-Hyphens - Artist-With-Hyphens".into();
        TrackMetadata::default().apply(&mut composite);
        assert_eq!(composite["display_title"], "Title-With-Hyphens");
        assert_eq!(composite["display_artist"], "Artist-With-Hyphens");

        let mut unknown = packet(
            "unknown",
            "lyrics",
            "home",
            "[00:10]we are going home",
            Some(11_000),
        );
        TrackMetadata::default().apply(&mut unknown);
        assert_eq!(unknown["display_title"], "");
        assert_eq!(unknown["title_is_lyric"], true);
    }
}
