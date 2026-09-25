# Speech model check fixture

`speech.wav` is the first ten seconds of the existing synthetic regression recording
`LokalBotTests/Fixtures/LiveTranscript/continuous-speech.wav`. That recording was
created locally with macOS `say`; it contains no meeting or personal audio.
It begins: “During this meeting we need to review the release schedule and confirm
who will handle the remaining work.”

The check uses actual speech, passes the configured language and vocabulary prompt,
and requires text containing words. It establishes that the transcription path ran;
it is not an accuracy benchmark or proof of every supported language.
