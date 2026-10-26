-- osascript open_terminal.applescript <command> <font size> <light|dark>
-- Opens one Terminal window running <command>, styled for filming. Only that
-- window's settings are changed; the person's Terminal profiles are not.
on run argv
	set theCommand to item 1 of argv
	set theSize to (item 2 of argv) as integer
	set theLook to item 3 of argv
	tell application "Terminal"
		set theTab to do script theCommand
		set theWindow to window 1
		set font name of theTab to "Menlo"
		set font size of theTab to theSize
		if theLook is "dark" then
			set background color of theTab to {7196, 8224, 10023}
			set normal text color of theTab to {60652, 62451, 63993}
			set cursor color of theTab to {60652, 62451, 63993}
		else
			set background color of theTab to {65535, 65535, 65535}
			set normal text color of theTab to {7967, 8995, 10280}
			set cursor color of theTab to {7967, 8995, 10280}
		end if
		set custom title of theTab to "launch-site"
		set title displays custom title of theTab to true
		set title displays device name of theTab to false
		set title displays shell path of theTab to false
		set title displays window size of theTab to false
		activate
	end tell
end run
