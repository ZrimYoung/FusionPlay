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
    qualified_title: Option<String>,
    sender_credit: Option<String>,
    artist: String,
    album: String,
    display_artist: Option<String>,
    stale_compound_artist: Option<String>,
    display_album: Option<String>,
    duration: Option<u64>,
    position: Option<u64>,
    lyrics: Lyrics,
}

impl TrackMetadata {
    pub(super) fn observe_position(&mut self, millis: u64) {
        self.position = Some(millis);
    }

    #[cfg(test)]
    fn apply(&mut self, event: &mut Value) {
        self.apply_with_navigation(event, false);
    }

    pub(super) fn apply_with_navigation(&mut self, event: &mut Value, navigation_restarted: bool) {
        let packet_id = text(event, "track_id");
        let packet_source = text(event, "track_id_source");
        let explicit = (packet_source == "explicit" && !packet_id.is_empty()).then_some(packet_id);
        let transport_title = raw(event, "raw_title", "title").to_owned();
        let transport_artist = raw(event, "raw_artist", "artist").to_owned();
        let transport_album = raw(event, "raw_album", "album").to_owned();
        let raw_title = transport_title.trim();
        let packet_artist = transport_artist.trim();
        let repeats_stale_artist = self.stale_compound_artist.as_deref() == Some(packet_artist);
        let artist = if repeats_stale_artist { "" } else { packet_artist };
        let album = transport_album.trim();
        let duration = event["duration_ms"].as_u64().filter(|ms| *ms > 0);
        let position = event["position_ms"].as_u64();
        let document = text(event, "lyrics_text");
        let same_document = !document.is_empty() && document == self.lyrics.source;
        let mut incoming = (!document.is_empty() && !same_document).then(|| Lyrics::parse(document));
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
        // Both parts must match already known labels. Try the original
        // compound first: a performer's name may itself end with the album.
        let composite_performer = [
            composite_artist(artist, &self.title, ""),
            composite_artist(artist, &self.title, &self.album),
        ].into_iter().flatten().find(|tail| {
            equivalent(tail, &self.artist)
                || self.display_artist.as_ref().is_some_and(|known| equivalent(tail, known))
        });
        // Some senders put captions in mTitle without supplying an LRC. A
        // verified title/performer compound supplies the missing continuity
        // evidence, but never overrides a new document or an explicit ID.
        let matching_compound = document.is_empty() && !raw_title.is_empty()
            && composite_performer.is_some();
        // A same-session navigation with a separately reported restart is
        // stronger than the previous song's delayed title/performer field.
        let stale_compound = navigation_restarted && explicit.is_none() && !same_title && matching_compound;
        let composite_continuity = matching_compound && !stale_compound;
        let metadata_agrees = compatible(album, &self.album)
            && (compatible(artist, &self.artist)
                || self
                    .display_artist
                    .as_ref()
                    .is_some_and(|known| equivalent(artist, known))
                || composite_performer.is_some())
            && duration
                .zip(self.duration)
                .is_none_or(|(new, old)| new.abs_diff(old) <= 2_000);
        // When both sides have explicit IDs they are authoritative. With
        // inferred IDs, a metadata-only update does not begin a new song.
        let same = !self.id.is_empty()
            && match (explicit, self.explicit_id.as_deref()) {
                (Some(new), Some(old)) => new == old,
                (Some(_), None) => metadata_agrees && (same_title || same_document || same_header),
                (None, _) if stale_compound => false,
                (None, _) => {
                    metadata_agrees
                        && (same_title
                            || same_document
                            || same_header
                            || late_document
                            || composite_continuity
                            || (incoming.is_none()
                                && self
                                    .lyrics
                                    .matches_caption(raw_title, position.or(self.position))))
                        || (raw_title.is_empty() && incoming.is_none())
                }
            };
        let position_is_caption_placeholder = same && composite_continuity && !same_title
            && position == Some(0) && self.position.is_some_and(|previous| previous > 1_500);
        let position = position.filter(|_| !position_is_caption_placeholder);
        let artist = if repeats_stale_artist && !same { packet_artist } else { artist };
        if !same && !packet_id.is_empty() {
            // A new identity still owns lyrics explicitly present in this
            // packet. Reuse the parsed document when it is byte-identical;
            // resetting below must not discard it just because parsing was
            // skipped before the identity decision.
            if same_document {
                incoming = Some(std::mem::take(&mut self.lyrics));
            }
            *self = Self {
                id: packet_id.to_owned(),
                id_source: packet_source.to_owned(),
                stale_compound_artist: stale_compound.then(|| packet_artist.to_owned()),
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
        let conflicting_headers = lyrics.title.conflicted || lyrics.artist.conflicted;
        let header = (!conflicting_headers).then(|| lyrics.song_title()).flatten();
        let known_album = lyrics.album.value.as_deref().unwrap_or(album);
        let composite = (!conflicting_headers).then(|| recover_composite(
            artist,
            header,
            lyrics.artist.value.as_deref(),
            album,
            known_album,
        )).flatten().or_else(|| {
            // Only reuse cached labels after the same-track decision. A new
            // explicit identity or conflicting document must not inherit them.
            composite_performer.filter(|_| same && composite_continuity)
                .map(|performer| (self.title.clone(), performer.to_owned()))
        });
        if conflicting_headers && !self.title_verified { self.title.clear(); }
        let candidate = header.or_else(|| composite.as_ref().map(|(name, _)| name.as_str()));
        let agrees_with_title = !raw_title.is_empty()
            && (candidate.is_some_and(|title| equivalent(raw_title, title))
                || (self.title_verified && equivalent(raw_title, &self.title)));
        let caption = !agrees_with_title
            && (event["title_is_lyric"].as_bool().unwrap_or(false)
                || lyrics.matches_caption(raw_title, position.or(self.position))
                || (same && composite_continuity));
        let previous_title = self.title.clone();
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
        } else if !conflicting_headers && self.display_artist.is_none() && (caption || artist.is_empty()) {
            self.display_artist = lyrics.artist.value.clone();
        }
        if !conflicting_headers && self.display_album.is_none() && (caption || album.is_empty()) {
            self.display_album = lyrics.album.value.clone();
        }
        if !stale_compound && !artist.is_empty() && (!caption || self.artist.is_empty()) {
            self.artist = artist.to_owned();
        }
        if !album.is_empty() {
            self.album = album.to_owned();
        }

        if !conflicting_headers {
            // The transport's full labels are presentation data. Keep them out
            // of the continuity comparisons above, which must still distinguish
            // a genuine track change from packets carrying the current lyric.
            let subtitle = sender_subtitle(artist, &self.title);
            let known_credit = self.sender_credit.as_deref().or(lyrics.artist.value.as_deref()
                .filter(|_| !self.title.is_empty()));
            let recovered_subtitle = subtitle.and_then(|(title, credit)| {
                let known_credit = known_credit?;
                let without_album = strip_suffix(credit, &self.album);
                [Some(credit), without_album].into_iter().flatten()
                    .find(|credit| equivalent(credit, known_credit))
                    .or_else(|| without_album
                        .or_else(|| (!credit.contains(is_dash)).then_some(credit))
                        .filter(|credit| includes_artist(credit, known_credit)))
                    .map(|credit| (title, credit))
            });
            let matches_current_title = !caption && !raw_title.is_empty()
                && (equivalent(raw_title, &self.title) || has_title_qualifier(raw_title, &self.title));
            let qualified_title = [
                matches_current_title.then_some(raw_title),
                recovered_subtitle.map(|(title, _)| title),
                self.qualified_title.as_deref(),
                Some(previous_title.as_str()),
            ].into_iter().flatten().find(|title| has_title_qualifier(title, &self.title))
                .map(str::to_owned);
            self.qualified_title = qualified_title;

            let sender_credit = recovered_subtitle.map(|(_, credit)| credit).or_else(|| {
                (subtitle.is_none() && !artist.is_empty()
                    && (matches_current_title || known_credit.is_some_and(|known| includes_artist(artist, known))))
                    .then_some(artist)
            });
            if let Some(credit) = sender_credit.filter(|_| !stale_compound) {
                // A later lyric packet can repeat only one of the credited artists.
                if !self.sender_credit.as_deref().is_some_and(|old| includes_artist(old, credit)) {
                    self.sender_credit = Some(credit.to_owned());
                }
            }
        }

        if !self.id.is_empty() {
            event["track_id"] = self.id.clone().into();
            event["track_id_source"] = self.id_source.clone().into();
            event["track_transition"] = if same { "same" } else { "new" }.into();
        }
        if !self.title.is_empty() || caption {
            let title = self.qualified_title.as_ref().unwrap_or(&self.title);
            event["display_title"] = title.clone().into();
        }
        let sender_credit = self.sender_credit.as_ref()
            .filter(|_| (caption || same) && !stale_compound);
        if let Some(artist) = sender_credit.or(self.display_artist.as_ref()) {
            event["display_artist"] = artist.clone().into();
        }
        let sender_album = (!self.album.is_empty()).then_some(&self.album);
        if let Some(album) = sender_album.or(self.display_album.as_ref()) {
            event["display_album"] = album.clone().into();
        }
        event["title_is_lyric"] = caption.into();
        if stale_compound || (same && repeats_stale_artist) {
            event["artist"] = Value::Null;
            event["artist_is_stale"] = true.into();
        }
        if position_is_caption_placeholder {
            event["position_ms"] = Value::Null;
        }
        // Keep the SDK's legacy labels unchanged: older Android/desktop
        // reducers do not understand projection fields. Apple Host consumers
        // opt into the exact sender labels through these additive raw fields.
        event["raw_title"] = transport_title.into();
        event["raw_artist"] = transport_artist.into();
        event["raw_album"] = transport_album.into();
    }
}

fn text<'a>(event: &'a Value, key: &str) -> &'a str {
    event[key].as_str().unwrap_or("").trim()
}

fn raw<'a>(event: &'a Value, raw_key: &str, legacy_key: &str) -> &'a str {
    event[raw_key]
        .as_str()
        .unwrap_or_else(|| event[legacy_key].as_str().unwrap_or(""))
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn label_fits(text: &str) -> bool {
    let string = objc2_core_foundation::CFString::from_str(text);
    let mut index = 0;
    let mut count = 0;
    while index < string.length() && count <= MAX_LABEL {
        // SAFETY: index is inside the owned string; each valid composed range
        // advances to the next boundary. Match Swift's character-based cap.
        let range = unsafe { string.range_of_composed_characters_at_index(index) };
        index = range.location + range.length;
        count += 1;
    }
    count <= MAX_LABEL
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn label_fits(text: &str) -> bool { text.chars().take(MAX_LABEL + 1).count() <= MAX_LABEL }

fn normalized(text: &str) -> String {
    let text = text.trim_matches(|c: char| c.is_whitespace() || c == '\u{feff}')
        .replace('’', "'");
    normalized_unicode(&text).split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn normalized_unicode(text: &str) -> String {
    use objc2_core_foundation::{CFLocale, CFMutableString, CFString,
        CFStringCompareFlags, CFStringNormalizationForm};
    let source = CFString::from_str(text);
    let Some(string) = CFMutableString::new_copy(None, 0, Some(&source)) else {
        return text.to_lowercase();
    };
    let locale_id = CFString::from_str("en_US_POSIX");
    let locale = CFLocale::new(None, Some(&locale_id));
    // Match the Mac display resolver: canonical composition, Unicode case
    // folding and width folding, without discarding accents or punctuation.
    // SAFETY: this is our owned mutable string and C is a defined form.
    unsafe { CFMutableString::normalize(Some(&string), CFStringNormalizationForm::C); }
    CFMutableString::fold(Some(&string),
        CFStringCompareFlags::CompareCaseInsensitive | CFStringCompareFlags::CompareWidthInsensitive,
        locale.as_deref());
    // Width folding can expose a combining mark after converting a full-width
    // base letter. Rust string equality needs the canonical form explicitly.
    unsafe { CFMutableString::normalize(Some(&string), CFStringNormalizationForm::C); }
    string.to_string()
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn normalized_unicode(text: &str) -> String { text.to_lowercase() }

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

fn has_title_qualifier(title: &str, base: &str) -> bool {
    if base.is_empty() || equivalent(title, base) {
        return false;
    }
    let Some((start, _)) = title.match_indices(['(', '（'])
        .find(|(start, _)| equivalent(&title[..*start], base))
    else {
        return false;
    };
    let mut depth = 0;
    for character in title[start..].chars() {
        match character {
            '(' | '（' => depth += 1,
            ')' | '）' if depth > 0 => depth -= 1,
            character if depth > 0 || character.is_whitespace() => {},
            _ => return false,
        }
    }
    depth == 0
}

fn sender_subtitle<'a>(source: &'a str, title: &str) -> Option<(&'a str, &'a str)> {
    if title.is_empty() {
        return None;
    }
    source.match_indices(is_dash).find_map(|(dash, value)| {
        let leading = source[..dash].trim();
        let trailing = source[dash + value.len()..].trim();
        (!trailing.is_empty() && (equivalent(leading, title) || has_title_qualifier(leading, title)))
            .then_some((leading, trailing))
    })
}

fn includes_artist(credit: &str, artist: &str) -> bool {
    if artist.is_empty() {
        return false;
    }
    // Preserve the complete sender string, including slashes inside names.
    // A slash only supplies evidence that a shorter header names one credit.
    equivalent(credit, artist) || credit.split('/').any(|part| equivalent(part, artist))
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
            || !label_fits(value)
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
        if title.is_empty() || !label_fits(title) {
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

    #[cfg(any(target_os = "macos", target_os = "ios"))]
    #[test]
    fn apple_projection_preserves_canonical_case_and_width_equivalence() {
        assert!(equivalent("Cafe\u{301}　ＨＯＭＥ", "Café home"));
        assert!(equivalent("Straße", "STRASSE"));
        assert!(!equivalent("Café", "Cafe"));
        let lyrics = "[ti:Night Walk]\n[ar:Example Artist]\n[00:10]We go höme together";
        let mut track = TrackMetadata::default();
        track.apply(&mut packet("stable", "lyrics_metadata", "go höme", lyrics, Some(10_000)));
        let mut caption = packet("caption-hash", "metadata", "ＧＯ　ＨＯ\u{308}ＭＥ", "", Some(10_500));
        track.apply(&mut caption);
        assert_eq!(caption["track_id"], "stable");
        assert_eq!(caption["track_transition"], "same");
        assert_eq!(caption["display_title"], "Night Walk");
    }

    #[test]
    fn conflicting_headers_do_not_recover_from_a_composite_artist() {
        for headers in [
            "[ti:First][ti:Other][ar:Artist]",
            "[ti:First][ar:Artist][ar:Other]",
        ] {
            let mut value = packet("id", "explicit", "touch her",
                &format!("{headers}\n[00:10]Someone may touch her tonight"), Some(10_000));
            value["raw_artist"] = "First - Artist".into();
            TrackMetadata::default().apply(&mut value);
            assert_eq!(value["display_title"], "");
            assert_eq!(value["title"], "touch her");
            assert!(value["display_artist"].is_null());
        }
    }

    #[test]
    fn label_limits_are_characters_not_utf8_bytes() {
        let title = "曲".repeat(200);
        let mut value = packet("id", "explicit", "touch her",
            &format!("[ti:{title}]\n[00:10]Someone may touch her tonight"), Some(10_000));
        TrackMetadata::default().apply(&mut value);
        assert_eq!(value["display_title"], title);
        assert!(!label_fits(&"曲".repeat(MAX_LABEL + 1)));
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        {
            assert!(label_fits(&"e\u{301}".repeat(MAX_LABEL)));
            assert!(label_fits(&"👩‍👩‍👧‍👦".repeat(MAX_LABEL)));
        }
    }

    #[test]
    fn lyric_headers_do_not_replace_richer_sender_labels() {
        const DOCUMENT: &str = "[ti:Night Walk][ar:Alpha][al:Night Walk]\n[00:10]we are heading home";
        let mut track = TrackMetadata::default();
        let mut first = packet("track", "explicit", "Night Walk (Live)", DOCUMENT, Some(0));
        first["raw_artist"] = "Alpha/Beta".into();
        first["raw_album"] = "Sender Album".into();
        track.apply(&mut first);

        let mut caption = packet("track", "explicit", "we are heading home", DOCUMENT, Some(10_000));
        caption["raw_artist"] = "Alpha".into();
        caption["raw_album"] = "".into();
        track.apply(&mut caption);
        assert_eq!(caption["track_transition"], "same");
        assert_eq!(caption["display_title"], "Night Walk (Live)");
        assert_eq!(caption["display_artist"], "Alpha/Beta");
        assert_eq!(caption["display_album"], "Sender Album");

        let mut next = packet("next", "explicit", "Night Walk", DOCUMENT, Some(0));
        next["raw_artist"] = "Alpha".into();
        next["raw_album"] = "Different Album".into();
        track.apply(&mut next);
        assert_eq!(next["track_transition"], "new");
        assert_eq!(next["display_title"], "Night Walk");
        assert!(next["display_artist"].is_null());
        assert_eq!(next["display_album"], "Different Album");
    }

    #[test]
    fn first_lyric_caption_can_recover_a_qualified_title_with_multiple_artists() {
        const DOCUMENT: &str = "[ti:Night Walk][ar:Alpha][al:Night Walk]\n[00:10]we are heading home";
        let mut track = TrackMetadata::default();
        let mut caption = packet("track", "explicit", "we are heading home", DOCUMENT, Some(10_000));
        caption["raw_artist"] = "Night Walk (Live) - Alpha/Beta - Sender Album".into();
        caption["raw_album"] = "Sender Album".into();
        track.apply(&mut caption);
        assert_eq!(caption["display_title"], "Night Walk (Live)");
        assert_eq!(caption["display_artist"], "Alpha/Beta");
        assert_eq!(caption["display_album"], "Sender Album");
    }

    #[test]
    fn known_title_prefix_is_not_cached_as_part_of_the_credit() {
        const DOCUMENT: &str = "[ti:Night Walk][ar:Alpha]\n[00:10]we are heading home";
        let mut track = TrackMetadata::default();
        let mut first = packet("track", "explicit", "Night Walk", DOCUMENT, Some(0));
        first["raw_artist"] = "Night Walk - Alpha".into();
        track.apply(&mut first);
        assert_eq!(first["display_artist"], "Alpha");

        let mut caption = packet("track", "explicit", "we are heading home", DOCUMENT, Some(10_000));
        caption["raw_artist"] = "Night Walk - Alpha".into();
        track.apply(&mut caption);
        assert_eq!(caption["display_artist"], "Alpha");
    }

    #[test]
    fn partial_credit_cannot_reclassify_an_unknown_album_as_an_artist() {
        const DOCUMENT: &str = "[ti:Night Walk][ar:Alpha]\n[00:10]we are heading home";
        let mut track = TrackMetadata::default();
        let mut caption = packet("track", "explicit", "we are heading home", DOCUMENT, Some(10_000));
        caption["raw_artist"] = "Night Walk - Alpha/Beta - Mystery suffix".into();
        caption["raw_album"] = "".into();
        track.apply(&mut caption);
        assert_eq!(caption["display_artist"], "Alpha");
        assert!(caption["display_album"].is_null());
    }

    #[test]
    fn late_sender_album_replaces_the_lyric_album_fallback() {
        const DOCUMENT: &str = "[ti:Night Walk][ar:Alpha][al:Night Walk]\n[00:10]we are heading home";
        let mut track = TrackMetadata::default();
        let mut first = packet("track", "explicit", "we are heading home", DOCUMENT, Some(10_000));
        first["raw_artist"] = "Alpha/Beta".into();
        first["raw_album"] = "".into();
        track.apply(&mut first);
        assert_eq!(first["display_artist"], "Alpha/Beta");
        assert_eq!(first["display_album"], "Night Walk");

        let mut later = packet("track", "explicit", "we are heading home", "", Some(10_500));
        later["raw_artist"] = "Alpha".into();
        later["raw_album"] = "Sender Album".into();
        track.apply(&mut later);
        assert_eq!(later["display_artist"], "Alpha/Beta");
        assert_eq!(later["display_album"], "Sender Album");
    }

    #[test]
    fn qualified_titles_and_credits_preserve_exact_raw_transport_labels() {
        const DOCUMENT: &str = "[ti:Night Walk][ar:Alpha][al:Header Album]\n[00:10]we are heading home";
        let mut track = TrackMetadata::default();
        let raw_title = "  we are heading home  ";
        let raw_artist = "  Night Walk (Explicit) - Alpha/Beta - Sender Album  ";
        let raw_album = "  Sender Album  ";
        let mut caption = packet("track", "explicit", raw_title, DOCUMENT, Some(10_000));
        caption["raw_artist"] = raw_artist.into();
        caption["raw_album"] = raw_album.into();
        track.apply(&mut caption);
        assert_eq!(caption["display_title"], "Night Walk (Explicit)");
        assert_eq!(caption["display_artist"], "Alpha/Beta");
        assert_eq!(caption["display_album"], "Sender Album");
        assert_eq!(caption["raw_title"], raw_title);
        assert_eq!(caption["raw_artist"], raw_artist);
        assert_eq!(caption["raw_album"], raw_album);
        assert_eq!(caption["title"], raw_title);
    }

    #[test]
    fn conflicting_lyric_headers_do_not_infer_rich_titles_or_credits() {
        for headers in ["[ti:First][ti:Other][ar:Artist]", "[ti:First][ar:Artist][ar:Other]"] {
            let mut track = TrackMetadata::default();
            let mut caption = packet("track", "explicit", "touch her",
                &format!("{headers}\n[00:10]Someone may touch her tonight"), Some(10_000));
            caption["raw_artist"] = "First (Live) - Artist/Partner - Sender Album".into();
            caption["raw_album"] = "Sender Album".into();
            track.apply(&mut caption);
            assert_eq!(caption["display_title"], "");
            assert!(caption["display_artist"].is_null());
            assert_eq!(caption["display_album"], "Sender Album");
        }
    }

    #[test]
    fn title_qualifiers_must_be_complete_suffixes_of_the_known_song() {
        for value in ["Night Walk (Live)", "Night Walk（Explicit）", "Night Walk (Live) (Remastered)"] {
            assert!(has_title_qualifier(value, "Night Walk"));
        }
        for value in ["Night Walk", "Night Walker (Live)", "Other (Live)", "Night Walk (Live", "Night Walk (Live) extra"] {
            assert!(!has_title_qualifier(value, "Night Walk"));
        }
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
    fn caption_without_lrc_keeps_verified_compound_labels_and_identity() {
        for (title, artist, album, compound) in [
            ("Synthetic", "Artist", "Record", "Synthetic-Artist"),
            ("A-B", "C-D", "Record", "A-B-C-D"),
            ("X", "Y-Z", "Record", "X—Y-Z"),
            ("T—One", "Artist – Two", "Album-1", "T—One - Artist – Two - Album-1"),
            ("Night Walk", "Example - Record", "Record", "Night Walk - Example - Record"),
        ] {
            let mut track = TrackMetadata::default();
            let mut first = packet("stable", "metadata", title, "", None);
            first["raw_artist"] = artist.into(); first["raw_album"] = album.into();
            first["duration_ms"] = 167_000.into();
            track.apply(&mut first);
            for (i, caption) in ["one", "A changing line", "home", "Another changing line"].iter().enumerate() {
                let mut next = packet(&format!("caption-{i}"), "metadata", caption, "", None);
                next["raw_artist"] = compound.into(); next["raw_album"] = album.into();
                next["duration_ms"] = 167_000.into();
                track.apply(&mut next);
                assert_eq!(next["track_transition"], "same", "{title} / {artist}");
                assert_eq!(next["track_id"], "stable");
                assert_eq!(next["display_title"], title);
                assert_eq!(next["display_artist"], artist);
                assert_eq!(next["title_is_lyric"], true);
                assert_eq!(next["raw_title"], *caption);
                assert_eq!(next["title"], *caption);
                assert_eq!(next["raw_artist"], compound);
                assert_eq!(track.artist, artist);
                assert!(track.lyrics.source.is_empty());
            }
        }
    }

    #[test]
    fn caption_compound_does_not_replace_stronger_new_track_evidence() {
        for (id, source, title, artist, lyrics, album, duration) in [
            ("next", "explicit", "Next song", "Synthetic-Artist", "", "Record", 167_000),
            ("next", "metadata", "Next song", "Artist", "", "Record", 167_000),
            ("next", "metadata", "Next song", "Next song-Artist", "", "Record", 167_000),
            ("next", "metadata", "caption", "Unknown-Artist", "", "Record", 167_000),
            ("next", "metadata", "caption", "Synthetic-Stranger", "", "Record", 167_000),
            ("next", "metadata", "caption", "Synthetic-Artist", "[ti:Next song]\n[00:00]caption", "Record", 167_000),
            ("next", "metadata", "caption", "Synthetic-Artist", "", "Other album", 167_000),
            ("next", "metadata", "caption", "Synthetic-Artist", "", "Record", 171_000),
        ] {
            let mut track = TrackMetadata::default();
            let mut first = packet("stable", "explicit", "Synthetic", "", None);
            first["raw_artist"] = "Artist".into(); first["duration_ms"] = 167_000.into();
            track.apply(&mut first);
            let mut verified = packet("first-caption", "metadata", "first line", "", None);
            verified["raw_artist"] = "Synthetic-Artist".into();
            verified["duration_ms"] = 167_000.into();
            track.apply(&mut verified);
            assert_eq!(verified["track_transition"], "same");
            assert!(track.title_verified);
            let mut next = packet(id, source, title, lyrics, None);
            next["raw_artist"] = artist.into(); next["raw_album"] = album.into();
            next["duration_ms"] = duration.into();
            track.apply(&mut next);
            assert_eq!(next["track_transition"], "new", "{source} / {title} / {artist}");
            assert_eq!(next["track_id"], "next");
            assert_eq!(next["raw_title"], title);
            assert_eq!(next["raw_artist"], artist);
            assert_ne!(next["display_title"], "Synthetic");
            assert!(next["display_artist"].is_null());
        }
    }

    #[test]
    fn known_album_suffix_in_composite_artist_keeps_the_track() {
        let mut track = TrackMetadata::default();
        track.apply(&mut packet("stable", "explicit", "home", LYRICS, Some(11_000)));
        let mut composite = packet("caption-hash", "metadata", "home", "", Some(11_100));
        composite["raw_artist"] = "Night Walk - Example Artist - Record".into();
        track.apply(&mut composite);
        assert_eq!(composite["track_transition"], "same");
        assert_eq!(composite["track_id"], "stable");
        assert_eq!(composite["display_title"], "Night Walk");
        assert_eq!(composite["display_artist"], "Example Artist");
        assert_eq!(track.lyrics.source, LYRICS);

        let mut next = packet("next-hash", "metadata", "Next song", "", Some(0));
        next["raw_artist"] = "Next song - Example Artist - Record".into();
        track.apply(&mut next);
        assert_eq!(next["track_transition"], "new");
        assert_eq!(next["track_id"], "next-hash");
        assert!(track.lyrics.source.is_empty());
    }

    #[test]
    fn composite_artist_does_not_guess_unknown_or_conflicting_album_suffixes() {
        for (known_album, incoming_album, suffix) in [
            ("Record", "Record", "Other record"),
            ("", "", "Record"),
            ("Record", "Other record", "Record"),
        ] {
            let mut track = TrackMetadata::default();
            let mut first = packet("stable", "explicit", "home", LYRICS, Some(11_000));
            first["raw_album"] = known_album.into();
            track.apply(&mut first);
            let mut next = packet("different", "metadata", "home", "", Some(11_100));
            next["raw_album"] = incoming_album.into();
            next["raw_artist"] = format!("Night Walk - Example Artist - {suffix}").into();
            track.apply(&mut next);
            assert_eq!(next["track_transition"], "new");
            assert_eq!(next["track_id"], "different");
        }
    }

    #[test]
    fn repeated_document_survives_an_explicit_identity_change() {
        repeated_document_survives_identity_reset("explicit", false);
    }

    #[test]
    fn repeated_document_survives_incompatible_inferred_metadata() {
        repeated_document_survives_identity_reset("lyrics_metadata", true);
    }

    fn repeated_document_survives_identity_reset(source: &str, change_album: bool) {
        let mut track = TrackMetadata::default();
        track.apply(&mut packet("old", "explicit", "home", LYRICS, Some(11_000)));

        let mut next = packet("next", source, "home", LYRICS, Some(11_100));
        if change_album { next["raw_album"] = "Other edition".into(); }
        track.apply(&mut next);
        // Different explicit IDs remain authoritative; incompatible inferred
        // metadata still starts a new identity. Neither policy is relaxed.
        assert_eq!(next["track_transition"], "new");
        assert_eq!(next["track_id"], "next");
        assert_eq!(track.lyrics.source, LYRICS);
        assert_eq!(next["display_title"], "Night Walk");

        let mut caption = packet("caption-hash", "metadata", "home", "", Some(11_200));
        if change_album { caption["raw_album"] = "Other edition".into(); }
        track.apply(&mut caption);
        assert_eq!(caption["track_transition"], "same");
        assert_eq!(caption["track_id"], "next");
        assert_eq!(caption["display_title"], "Night Walk");

        // An actual new song without a document must not inherit old lyrics.
        let mut without_document = packet("following", "explicit", "Next song", "", None);
        track.apply(&mut without_document);
        assert_eq!(without_document["track_transition"], "new");
        assert!(track.lyrics.source.is_empty());
        assert_eq!(without_document["display_title"], "Next song");
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
