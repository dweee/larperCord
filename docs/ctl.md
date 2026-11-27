# Controlling larperCord from outside (`larpercord ctl`)

`larpercord ctl` talks to the larperCord that is already running: mute and deafen, push to
talk, show or hide the window, open a channel, read the unread counts or follow them live. It
is meant for scripts, status bars and system shortcuts. The most useful case is **global push to
talk on Linux**: SDL has no global shortcut there, but your compositor does, and it can call
`larpercord ctl ptt-down` when you press a key and `larpercord ctl ptt-up` when you let go.

It works on Linux and Windows, with the window open, minimized or hidden in the tray.

## Turning it on and off

Settings → Advanced → **External control (larpercord ctl)**. It is on by default. Off, the app
doesn't listen at all: there is no port and no thread waiting for anyone.

Nobody else can use it: the app listens on `127.0.0.1` only, on a random port, and every
connection has to start with a random key that changes each time the app opens. The port and
the key are in a file only your user can read (`~/.config/larpercord/ctl.port` on Linux,
`%APPDATA%\larpercord\ctl.port` on Windows). Other users of the same computer can't read it,
and other computers can't reach the port.

Nothing runs while nobody uses it: one thread waits for a connection, blocked, and a command
is handled between the app's events, without drawing anything.

## Commands

| Command | What it does |
| --- | --- |
| `status` | Connection, account, call and unread counts, as JSON (below) |
| `unread` | Unread counts, as JSON: `{"mentions":3,"dms":1,"channels":5}` |
| `mute` / `unmute` / `toggle-mute` | Like the microphone button and `Ctrl+Shift+M` (the sound, what goes to Discord, saved for next time) |
| `deafen` / `undeafen` / `toggle-deafen` | Like the headphones button and `Ctrl+Shift+D` |
| `ptt-down` / `ptt-up` | Press and release push to talk |
| `ptt-toggle` | Press, or release if pressed (for shortcuts that can't send the key release) |
| `show` / `hide` / `toggle` | The window, like the tray menu and a click on the tray icon |
| `open <link or id>` | Opens a Discord message or channel link (`https://discord.com/channels/…`) or a channel ID, and brings the window up |
| `watch` | Keeps running and prints one line each time the status, the unread counts or the call change |
| `watch --waybar` | The same, as JSON for a waybar custom module |
| `watch --format text` | The same, as a plain line (polybar and others) |
| `mentions [n]` | The unread DMs and mentions (what the Inbox shows), newest first, as JSON: who, where, the start of the message and a `link` for `open`. A conversation you haven't opened yet comes as one line with an empty `text` and `count` new messages |
| `channels` | Servers, text and voice channels and DMs with their unread counts, as JSON, for a launcher (`open <id>` opens one) |
| `presence <online\|idle\|dnd\|invisible>` | Changes your status |
| `volume <id> <0-200>` | Someone's volume in the call, in percent, like the mixer |
| `inspect <command>` | Runs a command of the [Inspector](inspector.md): `inspect find <text>`, `inspect tree`, `inspect el <selector>`, `inspect net`, `inspect log`, `inspect shot file.png`… (`inspect help` lists them). Clicking and typing only work in demo mode or with "Let ctl click and type" on in the Inspector's Console |
| `help` | The list of commands |

The answer goes to standard output and the exit code is 0 when it worked, 1 when it didn't (the
reason goes to standard error). The voice commands answer with the new state
(`{"muted":true,"deafened":false}`, `{"ptt_held":true}`), the window ones with
`{"window":"shown"}` (`hidden` or `minimized`).

`status` looks like this (one line; spread out here):

```json
{"connected": true, "connection": "ready", "demo": false,
 "account": {"id": "123456789012345678", "name": "you"},
 "window": "shown", "presence": "online", "latency_ms": 42,
 "voice": {"muted": false, "deafened": false, "mode": "push_to_talk", "ptt_held": false,
           "call": {"state": "connected", "channel_id": "…", "channel": "General",
                    "guild_id": "…", "guild": "My server",
                    "members": [{"id": "…", "name": "Ana", "avatar": "https://cdn.discordapp.com/avatars/…",
                                 "speaking": true, "muted": false, "deafened": false,
                                 "self": false, "volume": 1.0}]}},
 "unread": {"mentions": 3, "dms": 1, "channels": 5}}
```

IDs are strings, like in Discord's own API. `call` is `null` outside a call, and `guild_id` and
`guild` are `null` in a DM call. `connection` is `ready`, `connecting`, `reconnecting`,
`offline`, `failed`, `rejected` or `logged_out` (the login screen). `mentions` counts like
Discord's red badge (DMs included); `dms` and `channels` count unread conversations and text
channels, leaving out the ones you muted. `presence` is `online`, `idle`, `dnd` or `invisible`, and
`latency_ms` is the gateway heartbeat (0 until it's measured). In a call, `members` lists who is in
it, with who is talking right now, so `watch` sends a line when someone starts or stops talking.

## Push to talk from a shortcut

First pick Settings → Voice → **Push to talk**. The key chosen there keeps working with the
window focused; the shortcut below adds a key that works everywhere. While a call is on,
`ptt-down` transmits until `ptt-up`, even with another window focused, and leaving the call
releases it. Outside push to talk mode the commands answer with an error and do nothing.

**Hyprland** (`~/.config/hypr/hyprland.conf`), a key held down:

```ini
bind  = , F13, exec, larpercord ctl ptt-down
bindr = , F13, exec, larpercord ctl ptt-up
```

**Sway** (`~/.config/sway/config`; `--no-repeat` so a held key doesn't send it again):

```
bindsym --no-repeat F13 exec larpercord ctl ptt-down
bindsym --release F13 exec larpercord ctl ptt-up
```

**i3** works the same way on X11 (`bindsym --release`).

**KDE Plasma**: System Settings → Keyboard → Shortcuts → Add New → Command or Script, command
`larpercord ctl ptt-toggle`, then pick the key. Plasma's shortcuts don't fire on release, so the
key works as a switch: press to talk, press again to stop.

**GNOME**: Settings → Keyboard → View and Customize Shortcuts → Custom Shortcuts → `+`, command
`larpercord ctl ptt-toggle`. Same as KDE: one press talks, the next one stops.

Any of them can also have a mute key: `larpercord ctl toggle-mute`.

## Status bars

**waybar** (`~/.config/waybar/config`, and add `"custom/larpercord"` to a module list):

```jsonc
"custom/larpercord": {
    "exec": "larpercord ctl watch --waybar",
    "return-type": "json",
    "format": "{icon} {}",
    "format-icons": {
        "offline": "⏻", "idle": "💬", "unread": "💬", "mention": "🔴",
        "call": "🔊", "talking": "🎙", "muted": "🔇", "deafened": "🎧"
    },
    "on-click": "larpercord ctl toggle",
    "on-click-right": "larpercord ctl toggle-mute",
    "on-click-middle": "larpercord ctl toggle-deafen"
}
```

Each line has `text` (the number of mentions, empty when there are none), `alt` (the main state,
for `format-icons`: `offline`, `idle`, `unread`, `mention`, `call`, `talking`, `muted` or
`deafened`; in a call the call state wins), `class` (every state that applies, for the CSS) and
`tooltip` (who you are, the call and the counts, in the app's language). For example, in
`~/.config/waybar/style.css`:

```css
#custom-larpercord.mention  { color: #f04747; }
#custom-larpercord.muted,
#custom-larpercord.deafened { color: #faa61a; }
#custom-larpercord.talking  { color: #43b581; }
```

When the app closes (or External control is turned off), the module shows `offline` and the
command keeps trying again every 3 seconds, so it comes back by itself when the app opens.

**polybar**:

```ini
[module/larpercord]
type = custom/script
exec = larpercord ctl watch --format text
tail = true
click-left = larpercord ctl toggle
click-right = larpercord ctl toggle-mute
```

The text line shows the call and its state, `@` with the mentions, `DM` with the unread
conversations and `#` with the unread channels, for example `General · muted · @3 · DM 1 · #5`.
It is empty when there is nothing to show.

For your own scripts, `watch` (without options) prints the same JSON as `status`, one line per
change. With `jq`:

```sh
larpercord ctl unread | jq .mentions
larpercord ctl watch | jq --unbuffered -r '.unread.mentions'
```

## Windows

The same commands, with the full path when `larpercord.exe` isn't on `PATH`
(`%LOCALAPPDATA%\Programs\larperCord\larpercord.exe` with the installer). On Windows the push
to talk key from Settings → Voice already works with another window focused, so `ctl` is for
everything else: other hotkeys, scripts, a Stream Deck.

**AutoHotkey v2**:

```ahk
#Requires AutoHotkey v2.0
lc := EnvGet("LOCALAPPDATA") "\Programs\larperCord\larpercord.exe"
^!m:: Run('"' lc '" ctl toggle-mute', , "Hide")
^!d:: Run('"' lc '" ctl toggle-deafen', , "Hide")
^!l:: Run('"' lc '" ctl toggle', , "Hide")
F13:: Run('"' lc '" ctl ptt-down', , "Hide")
F13 up:: Run('"' lc '" ctl ptt-up', , "Hide")
```

**A shortcut**: right-click the desktop → New → Shortcut, target
`"%LOCALAPPDATA%\Programs\larperCord\larpercord.exe" ctl toggle-mute`, then in its Properties
set a Shortcut key.

The release `larpercord.exe` is a windowed program, so `cmd` and PowerShell don't wait for it
and show its output after the next prompt. To read the answer in a terminal, pipe it:
`larpercord ctl status | more` (cmd) or `larpercord ctl status | Out-String` (PowerShell). The
exit code is only there when the terminal waited (`start /wait` in cmd, or a pipe).

## Trying it with the demo

The demo (`--demo`), the QA and `--shot` runs don't open the port, so they never get in the way
of the larperCord you use. With `LARPER_CTL=1` they do, in another file (`ctl-demo.port`); set
it for the command too:

```sh
LARPER_CTL=1 larpercord --demo &
LARPER_CTL=1 larpercord ctl status
```

`LARPER_CTL=/some/path/ctl.port` uses that file instead, on both sides.

## The protocol

To talk to it without the command, from your own program: read `<port> <key>` from the file,
connect to `127.0.0.1:<port>` and send the key as the first line. Then one command per line;
each answer is `OK` or `ERR <code> <message>`, the body lines, and a line with only `.` (a body
line that starts with `.` gets another `.` in front). `watch` doesn't end with the `.` until the
app closes. The error codes (`not_ptt`, `no_call`, `not_found`, `timeout`…) never change between
versions. The details are at the top of
[`src/app_ctl.zig`](../src/app_ctl.zig). A command waits at most 5 seconds for the app (then
`ERR timeout`), and at most 8 connections are open at the same time.
