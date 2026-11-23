# Cue Island

Cue Island is a native Mac teleprompter for reading a script while looking toward the camera. White text scrolls in a small black panel just below the camera notch on the built-in display. If the MacBook display is closed, the panel sits at the top center of the main display.

## Build and launch

Use an Apple Silicon Mac running macOS 14 or later and a recent version of Apple's Command Line Tools with a compatible Swift 6 compiler. The app was built with Swift 6.4.2. To install the Command Line Tools, run `xcode-select --install`.

From the repository root, run

```sh
./build.command
open ./CueIsland.app
```

The build script compiles the Swift source and signs the app locally. You can move the resulting `CueIsland.app` into Applications.

## Read a script

Paste your script into the editor, choose a playback mode, then click **Start teleprompter** or press **⌘Return**.

| Playback mode | How it works |
| --- | --- |
| **Timed WPM** | Scroll at 40–400 words per minute. The default is 150 WPM. Use the island's **−** and **+** buttons to adjust the pace in steps of 10 while reading. |
| **Follow my voice** | Read the English script aloud. The island advances as Apple's on-device speech recognizer matches your words and holds your place during pauses. |

During playback, press **Space** to pause or resume, or **Esc** to return to the editor. At the end of the script, **Space** starts it again. If the island shows **Click island for keys**, click it once to use the shortcuts.

## Voice and local storage

The first time you start **Follow my voice**, macOS asks for Speech Recognition and Microphone access. You can review both permissions in **System Settings → Privacy & Security**. Voice mode requires an available on-device English recognizer. If it is unavailable, choose **Start timed playback** to keep reading.

Cue Island saves your current script, playback mode, and reading speed in the app's local macOS preferences. Voice recognition runs on the Mac, and pausing or leaving voice playback stops microphone capture.
