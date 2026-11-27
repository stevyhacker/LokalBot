# App Store screenshot shot list (iPhone 6.9" and iPad 13")

Capture 8 to 10 shots using clean sample data (`-demoPaired YES`, `-demoRecordings YES`, `-demoHeldRecordings YES`, and the fresh welcome screen). Keep captions short (5 to 8 words) above crisp device frames.

| # | Screen | State / flag | Headline caption |
| --- | --- | --- | --- |
| 1 | Welcome & Instant Record | Fresh install + held recording | Record offline before pairing a computer |
| 2 | Live Recording | `-demoRecordingScreen YES` | Keep recording with the screen locked |
| 3 | Today & Day Digest | `-demoPaired YES -demoSection today` | Your day, meetings, and digest offline |
| 4 | Meeting Summary | `-demoPaired YES -demoMeeting <id> -demoTab summary` | Local summaries, decisions, and action items |
| 5 | Transcript & Evidence | `-demoPaired YES -demoMeeting <id> -demoTab transcript -demoAt 721` | Jump straight to the exact quote |
| 6 | Ask with Citations | `-demoPaired YES -demoSection ask` | Ask your meetings, share cited answers |
| 7 | Actions | `-demoPaired YES -demoSection actions` | Check off actions offline, sync later |
| 8 | Meetings & Upload Queue | `-demoPaired YES -demoSection meetings -demoRecordings YES` | Direct sync over Wi-Fi or Tailscale |
| 9 | Timeline & Projects (iPad 13") | `-demoPaired YES -demoSection timeline` | Review work sessions and tracked projects |
| 10 | Pairing & Privacy Settings | `-demoPaired YES -demoSection settings` | End-to-end encrypted, zero cloud servers |

Key points to highlight across the set:
- Shot 1 proves cold-install recording works with no login wall and no paired computer yet.
- Shot 2 shows the elapsed timer, live microphone level meter, optional title, and on-device privacy notice.
- Shots 3 to 5 cover offline reading of summaries, speaker transcripts, and Day Digests synced from Mac, Windows, or Linux.
- Shot 6 shows Ask with clickable citation badges and the Share sheet including cited meeting titles.
- Shots 7 to 10 show offline action check-off, From This Device upload status, iPad split layouts, Noise E2EE, Tailscale route, allowlisted data classes, and Face ID App Lock.
