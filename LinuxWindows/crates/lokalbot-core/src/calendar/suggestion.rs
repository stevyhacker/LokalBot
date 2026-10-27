//! `MeetingSpeakerSuggestion.swift`: names the Name Speaker sheet offers.
//! Picker choices only, never a speaker attribution: attendance does not
//! identify a voice.

use unicode_normalization::UnicodeNormalization as _;
use unicode_normalization::char::is_combining_mark;

use crate::model::CalendarParticipantIdentity;

#[derive(Clone, Debug, PartialEq)]
pub struct SpeakerSuggestion {
    pub id: String,
    /// `None` for a calendar guest with neither a name nor a usable address.
    pub name: Option<String>,
    pub calendar: Option<CalendarParticipantIdentity>,
}

/// Where a suggestion came from, for its badges.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SuggestionSource {
    Calendar,
    NameFromEmail,
    SuggestedName,
}

impl SpeakerSuggestion {
    /// Calendar guests first (same-named guests stay separate, each with its
    /// own identity), then hint names not already offered.
    pub fn choices(calendar: &[CalendarParticipantIdentity], hints: &[String]) -> Vec<Self> {
        let mut result: Vec<Self> = calendar
            .iter()
            .map(|guest| Self {
                id: format!("calendar:{}", guest.id),
                name: guest.suggested_speaker_name(),
                calendar: Some(guest.clone()),
            })
            .collect();
        let mut known: std::collections::HashSet<String> = result
            .iter()
            .filter_map(|s| s.name.as_deref().map(Self::name_key))
            .collect();
        for hint in hints {
            let name = hint.trim();
            let key = Self::name_key(name);
            if key.is_empty() || !known.insert(key.clone()) {
                continue;
            }
            result.push(Self {
                id: format!("hint:{key}"),
                name: Some(name.to_string()),
                calendar: None,
            });
        }
        result
    }

    pub fn sources(&self) -> Vec<SuggestionSource> {
        match &self.calendar {
            None => vec![SuggestionSource::SuggestedName],
            Some(guest) => {
                let mut sources = vec![SuggestionSource::Calendar];
                if guest.name.is_none() && guest.suggested_speaker_name().is_some() {
                    sources.push(SuggestionSource::NameFromEmail);
                }
                sources
            }
        }
    }

    /// Every query word appears in the name or address, ignoring case and
    /// accents, so "petrovic ana" finds "Ana Petrović". "đ" is typed as "d"
    /// or "dj".
    pub fn matches(&self, query: &str) -> bool {
        let text = [
            self.name.as_deref(),
            self.calendar
                .as_ref()
                .and_then(|c| c.email_address.as_deref()),
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(" ");
        ["d", "dj"].iter().any(|stroke| {
            let haystack = search_key(&text, stroke);
            search_key(query, stroke)
                .split_whitespace()
                .all(|word| haystack.contains(word))
        })
    }

    /// Whitespace-collapsed, case- and width-insensitive (accents kept).
    pub fn name_key(name: &str) -> String {
        name.split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .nfkc()
            .collect::<String>()
            .to_lowercase()
    }
}

fn search_key(text: &str, stroke: &str) -> String {
    text.to_lowercase()
        .replace('đ', stroke)
        .nfkd()
        .filter(|c| !is_combining_mark(*c))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn guest(id: &str, name: Option<&str>, email: Option<&str>) -> CalendarParticipantIdentity {
        CalendarParticipantIdentity::new(id, name, email).unwrap()
    }

    #[test]
    fn calendar_guests_lead_and_hints_fill_in_unknown_names() {
        let guests = [
            guest("one", Some("Ana Petrović"), Some("ana@one.example")),
            guest("two", None, Some("ana@two.example")),
            guest("three", None, Some("support@example.com")),
        ];
        let hints = [
            "ana petrović".to_string(),
            " Marko ".to_string(),
            "".to_string(),
        ];
        let choices = SpeakerSuggestion::choices(&guests, &hints);
        let ids: Vec<&str> = choices.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(
            ids,
            [
                "calendar:one",
                "calendar:two",
                "calendar:three",
                "hint:marko"
            ]
        );
        assert_eq!(choices[1].name.as_deref(), Some("Ana"));
        assert_eq!(choices[2].name, None, "a shared mailbox needs a typed name");
        assert_eq!(choices[0].sources(), [SuggestionSource::Calendar]);
        assert_eq!(
            choices[1].sources(),
            [SuggestionSource::Calendar, SuggestionSource::NameFromEmail]
        );
        assert_eq!(choices[3].sources(), [SuggestionSource::SuggestedName]);
    }

    #[test]
    fn search_ignores_case_accents_order_and_the_serbian_stroke() {
        let choice = SpeakerSuggestion {
            id: "x".into(),
            name: Some("Đorđe Petrović".into()),
            calendar: Some(guest(
                "x",
                Some("Đorđe Petrović"),
                Some("djordje@example.com"),
            )),
        };
        assert!(choice.matches("petrovic dorde"));
        assert!(choice.matches("Djordje"));
        assert!(choice.matches("example.com"));
        assert!(!choice.matches("ana"));
    }
}
