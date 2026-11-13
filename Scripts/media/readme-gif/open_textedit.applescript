-- osascript open_textedit.applescript <file.txt>
-- Waits for the document TextEdit opened on <file.txt>, brings it to the
-- front and puts the insertion point at the end. Open the file first with
-- `open -a TextEdit <file>` so TextEdit never shows its Open panel, which
-- blocks scripting. The document keeps TextEdit's plain-text font, the one
-- typed text gets: a line mixing two fonts makes TextEdit report a caret
-- taller than the typed text, and the suggestion is drawn above it.
on run argv
	set thePath to item 1 of argv
	set AppleScript's text item delimiters to "/"
	set theName to last text item of thePath
	set AppleScript's text item delimiters to ""
	tell application "TextEdit"
		set found to false
		repeat 40 times
			repeat with candidate in documents
				if name of candidate is theName then set found to true
			end repeat
			if found then exit repeat
			delay 0.25
		end repeat
		if not found then error "TextEdit did not open " & thePath
		activate
	end tell
	-- Command-Down Arrow: insertion point to the end of the document.
	tell application "System Events" to key code 125 using command down
end run
