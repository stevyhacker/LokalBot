//! "My microphone is me" is one value for the process, so this test has a
//! binary of its own: flipping it cannot race the library's other tests.

use lokalbot_core::{
    AttributionMethod, AttributionSource, Segment, SpeakerAttribution, SpeakerIdentity, Transcript,
};

#[test]
fn every_transcript_reader_follows_the_microphone_setting() {
    let transcript = Transcript {
        segments: vec![Segment {
            start: 0.0,
            end: 2.0,
            speaker: "local".into(),
            text: "Let's ship Friday.".into(),
            confidence: None,
            timing_precision: None,
            attribution: Some(SpeakerAttribution {
                source: AttributionSource::Microphone,
                identity: SpeakerIdentity::Unresolved,
                method: AttributionMethod::Track,
            }),
        }],
        ..Default::default()
    };

    assert!(SpeakerAttribution::microphone_is_user(), "on by default");
    assert_eq!(transcript.speaker_name("local"), "Me");
    assert!(transcript.markdown().contains("Me:** Let's ship Friday."));

    SpeakerAttribution::set_microphone_is_user(false);
    assert_eq!(transcript.speaker_name("local"), "Local speaker");
    assert_eq!(transcript.speaker_roster()["local"], "Local speaker");
    assert!(
        transcript
            .markdown()
            .contains("Local speaker:** Let's ship Friday.")
    );

    SpeakerAttribution::set_microphone_is_user(true);
    assert_eq!(transcript.speaker_name("local"), "Me");
}
