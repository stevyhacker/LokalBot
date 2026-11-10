# Spec

```text
GOAL:    A stranger understands that LokalBot holds on to what was decided and hands it back
         wherever they work, and remembers the amber sentence turning up seven times.
OUTPUT:  HyperFrames, 1920 x 1080, 30 fps
TIME:    48.4 s x 30 = 1452 frames. The voice is the clock: each scene is as long as its line
         and its action need, and nothing waits on music.
LOOK:    Ground: brand slate #0E151D, flat. From the agent scene on, brand mint #C9F1E7, rising from the bottom.
         One screen, #17222D, 1824 x 880 at (48, 200), top corners 32 px, held for 40 s: every
         scene plays on it, and footage is clipped to it.
         Ink: #F2F7F5 on slate, #0E141C on mint.
         One accent: amber #FBBF24, the robot's antenna light. It appears only as the highlighter
         on the decision (multiply over light windows, a solid block behind dark text in the
         terminal) and as the antenna light on the end card.
         Titles: Inter 900, 92 px (8.5% of the height), tracking -0.035em, one line, left 96, top 58.
         They never repeat the voice's sentence word for word.
         Terminal: JetBrains Mono 40 px on #0B1119, 64 columns, as recorded.
         Medium: the product's own windows, captured at 2x. Window shadow 0 30px 90px at 50%.
         No grain, no vignette, no glow.
OBJECTS: The app window (meetings list, live transcript, notes, transcript, Timeline), the Quick
         Recall panel, two TextEdit documents, the dictation panel, a terminal window, a Tab key,
         the macOS pointer (64 px),
         the LokalBot icon. All but the key, the pointer and the terminal's frame are captures.
MOTION:  Camera (window inside the screen): power2.inOut, 21-24 frames, one move at a time.
         Highlighter: scaleX 0 to 1 from the left, power3.out, 10-12 frames, after the line is read.
         Arrivals: expo.out, 12-15 frames. Exits: power3.in or power2.in, 11-14 frames.
         The swipe between apps: both sides power2.inOut, 15 frames, the same curve.
         Titles: on in 4-6 frames (blur 6-8 px to 0, per word 2 frames apart, or the whole line),
         then dead still; off in 4-5 frames.
SHOTS:   0-186       Call. Window fills the screen; frames 36-60 in on the live transcript; the
                     line arrives at frame 101; highlighter 110-121. Reads: "You decide it on a
                     call". Hard cut on the highlighted sentence.
         186-360     Notes. Same sentence, same place, now the decision; back out to the whole
                     window (187-211). Pointer in 261-282, click 285; the transcript opens; in on
                     the cited line 291-312; highlighter 315-331.
                     Reads: "LokalBot writes it down", then "Every note cites its line".
         360-515     Search. The panel opens over the dimmed notes; "lisbon" typed 374-397; down
                     the list 422-466 with four arrow keys to the call; highlighter on the mail
                     475-486. Reads: "One search brings it back". Swipe left.
         515-681     Autocomplete. TextEdit swipes in mid-sentence; the suggestion shows at 557;
                     the Tab key goes down seven times 590-647; highlighter 653-664.
                     Reads: "It finishes your sentence". The page leaves upward.
         681-897     Dictation. An empty page comes up; the shortcut goes down at 700 and the
                     camera drops to LokalBot's panel (698-716) while the request is heard and
                     previewed (716-833); release 841, back up to the page 837-854, the sentence
                     is written at 851; highlighter 863-874. Reads: "Say it, and it's written".
                     The window drops as the ground turns mint.
         897-1053    Agent. A terminal rises; the question is typed 920-956; Return 959; the
                     answer 993; highlighter 1008-1019. Reads: "Your agents can ask too".
                     Swipe left.
         1053-1212   Timeline. Monday's page swipes in; pointer in 1070-1088, click 1090, the
                     session opens; the list scrolls to the afternoon as the camera goes in on
                     that column alone (1127-1148); highlighter on the call 1158-1168, which
                     closes to a dot 1204-1212. Reads: "Your day, session by session".
                     The screen leaves downward.
         1212-1452   End card. The dot rises to the antenna (1214-1232); the icon forms under it;
                     the name wipes out of the mark 1237-1250; "Your personal context engine"
                     word by word as it is said (1265-1310); where to get it 1335; the note on
                     what is real 1383. The last line of the voice ends at frame 1432.
SOUND:   Voice: ElevenLabs, nine takes levelled to the same speech level; the dictated request
         is in the scene, not narration. Effects under it at 0.22-0.5: a pop on the first
         highlight, clicks on the two pointer clicks, key ticks on arrows, Tabs and Return,
         typing under typing, a whoosh on each change of app or ground, one impact when the
         light lands. Mastered to -16 LUFS, peak -1.5 dBFS. No music.
BANNED:  A dark void with small things floating in it; glow, particles, gradients, glass; a second
         accent colour; accent on titles; every scene entering the same way; titles that move
         after they land; drifting or breathing loops; corner labels; the logo before the end
         card; any drawn product UI; CSS filters on footage.
QA:      0.2 s (thumbnail: window and title), 4.6 s (highlight on the transcript line), 6.2 s
         (cut: sentence in the same place), 10.4 s (cited line), 16.4 s (mail and call rows),
         21.9 s (finished sentence), 26.2 s (dictation panel with the request), 29.4 s (dictated
         sentence), 34.4 s (answer), 39.8 s (the call on the Timeline), 47.9 s (end card).
```
