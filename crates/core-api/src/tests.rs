use super::*;

#[test]
fn parses_musicbrainz_artist_id_and_url() {
    let expected = Uuid::parse_str("20244d07-534f-4eff-b4d4-930878889970").unwrap();
    assert_eq!(
        parse_musicbrainz_artist_id("20244d07-534f-4eff-b4d4-930878889970").unwrap(),
        expected
    );
    assert_eq!(
        parse_musicbrainz_artist_id(
            "https://musicbrainz.org/artist/20244d07-534f-4eff-b4d4-930878889970/"
        )
        .unwrap(),
        expected
    );
}

#[test]
fn composition_layout_never_emits_more_than_five_tiles() {
    for count in 1..=5 {
        assert_eq!(composition_layout(count, "feature").len(), count);
    }
    assert_eq!(composition_layout(6, "feature").len(), 5);
}
