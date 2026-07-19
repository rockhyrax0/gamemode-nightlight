# gamemode-nightlight

Suspend KDE's Night Light and sets monitors brightness level while a game is running, then put
everything back the way it was when you quit. Hooks into
[GameMode](https://github.com/FeralInteractive/gamemode), so it happens
automatically on launch and exit: no wrapper script, no manual toggling, no
remembering.

I personally have Night Light toggled on 24/7 with my monitor brightness usually set to ~0% when not gaming. I created this because I found it annoying to manually toggle Night Light within KDE Plasma and then set my monitor brightness to 15%.

```ini
# ~/.config/gamemode.ini
[custom]
start=/home/you/.local/bin/gamemode-nightlight start
end=/home/you/.local/bin/gamemode-nightlight end
```

That's the whole integration.

## Requirements

- **KDE Plasma 6.2 or newer.** Brightness goes through the
  `org.kde.ScreenBrightness` D-Bus service, which landed with per-display
  brightness control in Plasma 6.2. Older Plasma has nothing for this to talk to.
- **[GameMode](https://github.com/FeralInteractive/gamemode)**, running as a user
  service, with games launched via `gamemoderun %command%`.
- `kde-inhibit` (plasma-workspace), `busctl` (systemd), `setsid` (util-linux),
  and bash 4+. All of these are almost certainly already installed.

Wayland and X11 both work.

**Will brightness control work on my monitor?** Open the Brightness and Colour
applet and drag the slider for that display. If Plasma can move it, so can this
script: same code path. If Plasma can't (no DDC/CI support, monitor has it
disabled in its OSD, or `POWERDEVIL_NO_DDCUTIL=1` is set), the Night Light half
still works fine on its own.

## Install

```bash
git clone https://github.com/rockhyrax0/gamemode-nightlight.git
cd gamemode-nightlight
chmod +x gamemode-nightlight install.sh   # a no-op if the exec bit is already set;
                                          # needed if you downloaded the ZIP instead
./install.sh
```

`install.sh` checks dependencies, installs to `~/.local/bin/gamemode-nightlight`,
lists your detected displays, and prints the exact config block to paste. Undo it
with `./install.sh --uninstall`.

By hand, if you'd rather:

```bash
install -Dm755 gamemode-nightlight ~/.local/bin/gamemode-nightlight
```

Then add the `[custom]` block from the top of this README to
`~/.config/gamemode.ini`, creating the file if it doesn't exist. **Use an
absolute path**: gamemoded's environment won't reliably have `~/.local/bin` on
`$PATH`. If you already have a `[custom]` section, add the two lines to it rather
than starting a second one.

GameMode watches `gamemode.ini` and picks up changes on its own. If it doesn't
seem to have noticed:

```bash
systemctl --user restart gamemoded
```

## Configuration

Edit the block at the top of the script.

| Variable | Default | What it does |
|---|---|---|
| `BRIGHTNESS_PERCENT` | `15` | Gaming brightness, as a percent of each display's max, not a raw DDC value, so it does the right thing across displays with different scales. |
| `TARGET_DISPLAYS` | `external` | Which displays to dim: `external`, `all`, or `internal`. |
| `TARGET_LABEL` | `""` (off) | Pin to one monitor by EDID model name. If set, only displays whose label contains this text get dimmed (case-insensitive substring), and `TARGET_DISPLAYS` is ignored. |
| `SHOW_OSD` | `0` | `1` pops the brightness OSD on every change. `0` keeps it silent. |

### Finding your monitor's label

`org.kde.ScreenBrightness` identifies displays by EDID model name, not by
connector name. There's no `DP-1` to match on here. To see what yours are called:

```bash
for d in $(busctl --user get-property org.kde.ScreenBrightness \
             /org/kde/ScreenBrightness org.kde.ScreenBrightness DisplaysDBusNames \
             | grep -oP '"[^"]+"' | tr -d '"'); do
  printf '%s\t%s\n' "$d" "$(busctl --user get-property org.kde.ScreenBrightness \
    "/org/kde/ScreenBrightness/$d" org.kde.ScreenBrightness.Display Label)"
done
```

```
display0	s "27GL850"
display1	s "U2719DC"
```

Any substring works: `TARGET_LABEL="27GL850"` is enough to pin to the first one.

## Testing it

Run the two halves by hand first:

```bash
gamemode-nightlight start   # Night Light off, target display dims
gamemode-nightlight end     # both restored
```

Then launch a game and watch the daemon:

```bash
journalctl --user -u gamemoded -f
```

You want to see `Executing script [...]` on launch and exit, and the game should
appear immediately, no pause between clicking Play and the window showing up. If
there is one, see the second design note below.

## How it works

Two decisions in here are non-obvious and both were arrived at the hard way.

### Brightness goes through PowerDevil, not ddcutil

The obvious implementation is `ddcutil setvcp 10 15`. Don't.

Since Plasma 6.2, PowerDevil owns external monitor brightness. It drives
libddcutil itself, and it's what backs the slider in the Brightness and Colour
applet. A direct `ddcutil` call still changes the monitor, but PowerDevil never
finds out, so the slider desyncs: it shows a stale value, and the next time
PowerDevil writes brightness it does so from its stale idea of where things were.

Calling `org.kde.ScreenBrightness` over D-Bus instead keeps everything coherent,
because it's the same path the slider uses. It's also *much* faster: PowerDevil
keeps the monitor's DDC handle warm, whereas spawning `ddcutil` re-probes the I2C
bus every single invocation. That probe is where the multi-second lag in
ddcutil-based brightness scripts comes from.

### Every background job is detached from GameMode's pipe

This one costs you ten seconds on every single game launch if you get it wrong.

GameMode runs custom scripts with `/bin/sh -c`, with the child's stdout *and*
stderr wired to a pipe, then reads that pipe with `select()` bounded by
`script_timeout` (10 seconds by default). It's waiting for EOF.

EOF arrives only when every copy of the pipe's write end is closed. A backgrounded
job inherits the script's stdout and stderr, so the natural-looking

```bash
kde-inhibit --colorCorrect sleep infinity &
```

holds that pipe open for as long as the game runs. GameMode dutifully waits out
its entire timeout before letting the game start. Nothing errors. Nothing logs.
Your game just takes ten seconds longer to appear, forever.

The fix is two parts, both required:

- `>/dev/null 2>&1 </dev/null` on every background job, so none of them hold a
  copy of the pipe and EOF lands the moment the main script exits.
- `setsid --fork` for the inhibitor, so it survives on its own and leads its own
  process group. That's what makes the negative-PID `kill -TERM -- "-$pid"` on
  `end` reap `kde-inhibit` *and* the `sleep infinity` it wraps, instead of
  orphaning a sleep on every game you play.

This trap isn't specific to this script. Any GameMode custom script that
backgrounds a long-lived process walks into it.

## State

Two files, both in `$XDG_RUNTIME_DIR` (tmpfs, cleared on reboot):

| File | Contents |
|---|---|
| `gamemode-nightlight.pid` | The inhibitor's process group id, for teardown. |
| `gamemode-brightness.state` | Pre-game brightness per display, for restore. |

If a game hard-crashes without `end` ever running, the next `start` clears the
stale inhibitor before creating a new one. To clean up immediately, just run
`gamemode-nightlight end` by hand.

## Troubleshooting

**Night Light suspends but brightness doesn't move.** Check Plasma's own slider
for that display first. If it can't move it, neither can this. Also check you
don't have `POWERDEVIL_NO_DDCUTIL=1` set anywhere.

**Nothing happens at all.** `journalctl --user -u gamemoded -f` while launching.
No `Executing script` line means GameMode isn't reading your config. Confirm the
file is at `~/.config/gamemode.ini` and that the paths in it are absolute.

**The wrong monitor brightens/dims.** Set `TARGET_LABEL` (see above).

**Games take ~10s to launch.** Something in your `[custom]` scripts is holding
GameMode's pipe open. If it's not this script, it's another one. See the second
design note.

**Brightness didn't come back.** `end` never ran. Run it by hand;
`gamemode-brightness.state` still has your old values, unless you've rebooted since.

## License

MIT. See [LICENSE](LICENSE).
