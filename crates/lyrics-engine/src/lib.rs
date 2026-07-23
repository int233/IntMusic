use protocol::{LyricCue, LyricSegment};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ParsedLyrics {
    pub cues: Vec<LyricCue>,
    pub embedded_offset_ms: i64,
}

pub fn parse_lyrics(
    kind: &str,
    text: &str,
    translation: Option<&str>,
    pronunciation: Option<&str>,
    external_offset_ms: i64,
) -> ParsedLyrics {
    let timed = kind.eq_ignore_ascii_case("lrc")
        || text.lines().any(|line| timestamps_at_start(line).is_some());
    if !timed {
        return ParsedLyrics {
            cues: text
                .lines()
                .filter_map(|line| {
                    let text = line.trim();
                    (!text.is_empty()).then(|| LyricCue {
                        text: text.to_string(),
                        ..LyricCue::default()
                    })
                })
                .collect(),
            embedded_offset_ms: 0,
        };
    }

    let (mut cues, embedded_offset_ms) = parse_lrc_track(text);
    let translation = translation.map(parse_lrc_track);
    let pronunciation = pronunciation.map(parse_lrc_track);
    for cue in &mut cues {
        cue.start_ms = (cue.start_ms + embedded_offset_ms + external_offset_ms).max(0);
        for segment in &mut cue.segments {
            segment.start_ms = (segment.start_ms + embedded_offset_ms + external_offset_ms).max(0);
        }
        for index in 0..cue.segments.len().saturating_sub(1) {
            cue.segments[index].end_ms = Some(cue.segments[index + 1].start_ms);
        }
        cue.translation = translation
            .as_ref()
            .and_then(|(track, offset)| text_at(track, cue.start_ms - external_offset_ms - offset));
        cue.pronunciation = pronunciation
            .as_ref()
            .and_then(|(track, offset)| text_at(track, cue.start_ms - external_offset_ms - offset));
    }
    cues.sort_by_key(|cue| cue.start_ms);
    for index in 0..cues.len().saturating_sub(1) {
        let end_ms = Some(cues[index + 1].start_ms);
        cues[index].end_ms = end_ms;
        if let Some(segment) = cues[index].segments.last_mut() {
            segment.end_ms = end_ms;
        }
    }
    ParsedLyrics {
        cues,
        embedded_offset_ms,
    }
}

fn parse_lrc_track(text: &str) -> (Vec<LyricCue>, i64) {
    let mut cues = Vec::new();
    let mut offset_ms = 0;
    for raw_line in text.lines() {
        let line = raw_line.trim();
        if let Some(value) = line
            .strip_prefix("[offset:")
            .and_then(|value| value.strip_suffix(']'))
            .and_then(|value| value.trim().parse::<i64>().ok())
        {
            offset_ms = value;
            continue;
        }
        let Some((timestamps, lyric)) = timestamps_at_start(line) else {
            continue;
        };
        let (speaker, lyric) = split_speaker(lyric.trim());
        let (lyric, segments) = parse_enhanced_segments(lyric);
        for timestamp in timestamps {
            cues.push(LyricCue {
                start_ms: timestamp,
                end_ms: None,
                text: lyric.clone(),
                translation: None,
                pronunciation: None,
                speaker: speaker.clone(),
                background: false,
                segments: segments.clone(),
            });
        }
    }
    cues.sort_by_key(|cue| cue.start_ms);
    (cues, offset_ms)
}

fn text_at(cues: &[LyricCue], start_ms: i64) -> Option<String> {
    cues.iter()
        .find(|cue| (cue.start_ms - start_ms).abs() <= 20)
        .map(|cue| cue.text.clone())
        .filter(|text| !text.is_empty())
}

fn timestamps_at_start(mut line: &str) -> Option<(Vec<i64>, &str)> {
    let mut values = Vec::new();
    loop {
        let Some(rest) = line.strip_prefix('[') else {
            break;
        };
        let Some(end) = rest.find(']') else {
            break;
        };
        let token = &rest[..end];
        let Some(timestamp) = parse_timestamp(token) else {
            break;
        };
        values.push(timestamp);
        line = &rest[end + 1..];
    }
    (!values.is_empty()).then_some((values, line))
}

fn parse_timestamp(value: &str) -> Option<i64> {
    let (minutes, seconds) = value.split_once(':')?;
    let minutes = minutes.trim().parse::<i64>().ok()?;
    let (seconds, fraction) = seconds
        .split_once('.')
        .or_else(|| seconds.split_once(','))
        .unwrap_or((seconds, ""));
    let seconds = seconds.trim().parse::<i64>().ok()?;
    if minutes < 0 || !(0..60).contains(&seconds) {
        return None;
    }
    let fraction = fraction.trim();
    let millis = match fraction.len() {
        0 => 0,
        1 => fraction.parse::<i64>().ok()? * 100,
        2 => fraction.parse::<i64>().ok()? * 10,
        _ => fraction[..3.min(fraction.len())].parse::<i64>().ok()?,
    };
    Some(minutes * 60_000 + seconds * 1_000 + millis)
}

fn split_speaker(text: &str) -> (Option<String>, &str) {
    let Some(rest) = text.strip_prefix("<v ") else {
        return (None, text);
    };
    let Some(end) = rest.find('>') else {
        return (None, text);
    };
    let speaker = rest[..end].trim();
    if speaker.is_empty() {
        return (None, text);
    }
    (Some(speaker.to_string()), rest[end + 1..].trim_start())
}

fn parse_enhanced_segments(text: &str) -> (String, Vec<LyricSegment>) {
    let mut rest = text;
    let mut plain = String::new();
    let mut segments = Vec::new();
    while let Some(start) = rest.find('<') {
        plain.push_str(&rest[..start]);
        let candidate = &rest[start + 1..];
        let Some(end) = candidate.find('>') else {
            plain.push_str(&rest[start..]);
            rest = "";
            break;
        };
        let Some(timestamp) = parse_timestamp(&candidate[..end]) else {
            plain.push_str(&rest[..start + end + 2]);
            rest = &candidate[end + 1..];
            continue;
        };
        rest = &candidate[end + 1..];
        let next = rest.find('<').unwrap_or(rest.len());
        let segment_text = &rest[..next];
        plain.push_str(segment_text);
        segments.push(LyricSegment {
            start_ms: timestamp,
            end_ms: None,
            text: segment_text.to_string(),
        });
        rest = &rest[next..];
    }
    plain.push_str(rest);
    (plain, segments)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_multiple_timestamps_offsets_and_speakers() {
        let parsed = parse_lyrics(
            "lrc",
            "[offset:100]\n[00:01.20][00:02.300]<v Adele>Hello",
            None,
            None,
            50,
        );
        assert_eq!(parsed.cues.len(), 2);
        assert_eq!(parsed.cues[0].start_ms, 1_350);
        assert_eq!(parsed.cues[0].end_ms, Some(2_450));
        assert_eq!(parsed.cues[0].speaker.as_deref(), Some("Adele"));
        assert_eq!(parsed.cues[0].text, "Hello");
    }

    #[test]
    fn attaches_translation_and_pronunciation_by_timestamp() {
        let parsed = parse_lyrics(
            "lrc",
            "[00:01.00]hello",
            Some("[00:01.00]你好"),
            Some("[00:01.00]ni hao"),
            0,
        );
        assert_eq!(parsed.cues[0].translation.as_deref(), Some("你好"));
        assert_eq!(parsed.cues[0].pronunciation.as_deref(), Some("ni hao"));
    }

    #[test]
    fn preserves_plain_text_as_untimed_cues() {
        let parsed = parse_lyrics("text", "first\n\nsecond", None, None, 0);
        assert_eq!(parsed.cues.len(), 2);
        assert_eq!(parsed.cues[1].text, "second");
    }

    #[test]
    fn parses_enhanced_lrc_word_timestamps() {
        let parsed = parse_lyrics(
            "lrc",
            "[00:01.00]<00:01.00>Hello <00:01.50>world",
            None,
            None,
            0,
        );
        assert_eq!(parsed.cues[0].text, "Hello world");
        assert_eq!(parsed.cues[0].segments.len(), 2);
        assert_eq!(parsed.cues[0].segments[0].start_ms, 1_000);
        assert_eq!(parsed.cues[0].segments[0].end_ms, Some(1_500));
        assert_eq!(parsed.cues[0].segments[1].text, "world");
    }
}
