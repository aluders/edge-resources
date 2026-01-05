keyboard maestro on mac...

+ shift-command-t

new macro - paste clipboard by typing
trigger - hotkey
action - pause (0.5)
action - keystroke delay (0.05)
action - insert text by typing
	%SystemClipboard%

+ shift-command-r (RDP safe)

new macro - paste clipboard by typing
trigger - hotkey
action - pause (0.5)
action - execute applescript

set theText to the clipboard
tell application "System Events"
	repeat with c in theText
		keystroke c
		delay 0.07
	end repeat
end tell
