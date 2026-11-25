# TheWatcher

A macOS menu-bar app that answers "is it the network?" at a glance. A single
dot shows the health of the internet link. Clicking it explains what's wrong
and where, and a history window shows how each place's connection has behaved
over time. It has to be cheap enough to run all day without feeling bad about
it, both on the Mac and on the network.

## The user experience

**The dot** sits in the menu bar. Its color is the worst thing in the last few
minutes, ordered by urgency:

- **Green:** fine.
- **Yellow:** a burp that has already cleared, or one missed ping not yet
  confirmed. It fades back to green after five clean minutes. A glance at
  yellow says "you're not crazy, something happened, it's over."
- **Orange:** going south right now. Pings are slow compared with this place's
  normal, or scattered pings are being lost.
- **Red:** nothing is getting through.
- **Hollow gray:** not connected, or waiting at a network login page. Neither
  is the internet failing.

**The panel**, opened by clicking the dot, answers "what's up". It leads with
one sentence saying what's wrong and where ("Your ISP's line looks down. Your
Wi-Fi and router are fine. Down for 2m 13s."). Below that is a live view of the
last 15 minutes: one strip per stop on the path, a "Your apps" strip for resend
bursts in the Mac's own traffic, and a latency chart against the usual latency.
The footer names the place, has "More details…", and a gear menu with Settings
and Quit. The panel's view exists only while it's open.

**More details** is a separate window holding the history for one kept place:

- Reliability over the last 30 days, measured only over watched time: "99.7%
  up across 412 watched hours · 3 outages, longest 6m".
- A day-by-hour grid, one row per day and one column per hour, colored by
  latency compared with that place's typical latency. Daily patterns like
  "always bad around 5pm" show up as a vertical stripe.
- Clicking an hour opens it as a chart. Within the last week it shows every
  ping; older hours show per-minute summaries.

**Settings:**

- A checkbox for one notification when an outage ends. Nothing is sent when
  one starts.
- Open at login. The installed app asks once, at first launch.
- The list of kept places, plus "Keep history here" when the current network
  isn't kept. Each place can be renamed, forgotten, or re-learned. Re-learning
  sets aside what was normal there, for a connection that has changed for
  good; the next 20 samples set the new normal.

## What is measured

**The path.** At startup, on any network change, and on wake, TheWatcher reads
the router from the system network state (`State:/Network/Global/IPv4`). It
then runs its own unprivileged ICMP traceroute toward 1.1.1.1, which needs no
root. From that route it picks the stops worth watching:

- **Router:** the first stop. Its strip is labeled by how the Mac connects
  ("Wi-Fi → router", "Ethernet → router", "Hotspot → phone").
- **Upstream router:** the first private-address stop behind the router. In a
  home with a mesh behind an ISP gateway, this is the ISP's box.
- **ISP:** the first public-address stop.
- **Internet:** the far hosts.

The route is remembered, not re-traced continuously. A middle stop going silent
while the internet still answers means the route moved, so that triggers a
re-trace, at most once every five minutes.

**Far hosts.** Cloudflare (1.1.1.1) and Google (8.8.8.8), taken in turns. If
one doesn't answer, the other is tried at once. An internet probe fails only
when both companies fail to answer, so a hiccup at one never reads as your
internet being down.

**Pacing.** Normally the router, the upstream router and the internet are each
pinged every 10 seconds, and the ISP stop every 30. When pings are being lost,
every stop gets one ping a second, so a short outage's end is timed to about a
second. Slowness alone never speeds pinging up; it measures fine at the normal
pace. Once-a-second pinging lasts at most 3 minutes at a stretch. After that,
continuing trouble is watched at the normal pace, and the end of a long outage
is timed to within 10 seconds. A login page drops back to the normal pace too.

**The Mac's own traffic.** Blips you actually feel happen on traffic the Mac is
already sending, so TheWatcher reads per-connection TCP statistics from the
kernel once a second: packets, bytes received, and bytes resent. This
adds no network traffic. Several connections resending in the same second is a
burp. During an outage this data also narrows when it started: data still
arriving proves the link worked, and resends with nothing arriving prove it
didn't. An outage's start is stored as a range rather than an invented exact
time.

The statistics come from the kernel's private network-statistics control socket
(`com.apple.network.statistics`, xnu `bsd/net/ntstat.c`). This is what `nettop`
reads. The vendored headers in `Sources/CNetStat/xnu/` are the published xnu
sources (APSL).

- On macOS, `net.statistics_privcheck` is 0, so an ordinary app may subscribe
  to the classic TCP provider.
- Replies arrive aggregated and in fragments. A bulk query is re-sent with the
  same context while the kernel flags `NSTAT_MSG_HDR_FLAG_CONTINUATION`.
- `nstat_avg_rtt` is the kernel's `t_srtt`, in milliseconds shifted left by 5.
- `nstat_txretransmit` counts resent bytes, not packets. A burst is at least
  three connections resending in the same second, totaling at least 15 KB
  (about ten full packets).
- The message layout has been byte-identical since macOS 10.13. When Apple
  tightened access in macOS 13.1, it left the TCP provider open.

If the kernel refuses access, the traffic monitor simply doesn't exist, the
"Your apps" strip disappears, and the pings carry on alone.

## How the dot is decided

`Evaluator.assess` is a pure function over a snapshot. Only the internet probes
set the color; the other stops explain where a problem starts.

- **Red:** the last three internet probes were all lost.
- **Orange:** either of these:
  - At least two lost pings among the last 20 internet probes (within 3
    minutes), not counting losses that belong to an outage run.
  - The median of the last five successful probes is above this place's slow
    threshold.
- **Yellow:** either of these:
  - One or two trailing lost probes (unconfirmed).
  - Within the last 5 minutes: a lost probe, a spike over the threshold, a lost
    router ping, a resend burst, or an outage that ended.
- **Slow threshold:** `max(2.5 × median, median + 4 × (p90 − median), median +
  50 ms)`, learned per place from the last 600 good samples. Nothing counts as
  slow until 20 samples exist. Those first 20 are learned whatever they are,
  so a link that is always slow becomes its own normal. After that, samples
  taken while the dot is orange or red are kept out of the baseline.
- **Locating the problem:**
  - Red is placed at the nearest stop losing at least half the pings sent
    since the internet stopped answering. Pings from before the outage don't
    count.
  - Orange loss is placed at the nearest stop losing at a comparable rate over
    the same stretch of time.
  - Slowness is placed at the router hop when the router itself is slow
    compared with its own baseline.
  - A silent or slow router means either the Mac's own link or the router
    itself. In a mesh, the router stop is the main node, and the node the Mac
    talks to relays without showing up on the path. The text names both and
    never blames the link alone.

## Places and history

A place is identified by its router's hardware address. No permission is
needed for that.

- It is read from the system's record of the primary network service
  (`ARPResolvedHardwareAddress` under `State:/Network/Service/<id>/IPv4`).
  macOS 27 hides the ARP table and neighbor addresses from ordinary apps, but
  not this record.
- Wired and Wi-Fi on the same network report the same router address, so
  they are the same place.

- The address stays the same anywhere on one network: a mesh has one router,
  and its satellites only relay Wi-Fi. Moving between eero nodes in different
  rooms showed the same router address and the same fingerprint.
- Wi-Fi names aren't used, because macOS hides them from apps without Location
  access.

History is kept only for places the user names in Settings. Up to a handful is
the expected use. Everything else is watched live but never stored.

History lives in SQLite at `~/Library/Application Support/TheWatcher/history.sqlite`:

- **Every ping,** and every second with resends: kept for 7 days, pruned
  automatically.
- **One-minute summaries:** kept forever. Each holds pings sent and lost,
  median and maximum latency, resends, and the worst color.
- **Outages:** kept forever, each stored as a start range plus an end.

Time away from a place (lid closed, at another network) is unwatched. It never
counts as up or down. Moving to another network discards the live measurements
and the learned baselines, because they say nothing about the new network.

## Code layout

- `Sources/CNetStat`: C shim over the kernel statistics socket.
- `Sources/WatcherCore`: everything testable without a UI.
  - `Pinger`: the ICMP socket.
  - `PathDiscovery`: router, fingerprint, traceroute, and choosing the stops.
  - `TrafficMonitor`
  - `Evaluator`: the color and the sentence.
  - `Baseline`
  - `HistoryStore`
  - `HistoryGrid`
  - `Watch`: every decision, as a pure state machine. Events go in (clock
    ticks, ping results, network changes, sleep and wake, traffic samples) and
    actions come out (send a ping, discover the path, record history,
    notify). It reads time only from its events. It handles pacing, learning,
    outage tracking, and minute summaries.
  - `Monitor`: performs `Watch`'s actions and feeds the results back in. It
    owns the clock, the network-change notices, the pinger, discovery, the
    traffic reader, and the store. It contains no decisions of its own.
- `Sources/TheWatcher`: the AppKit and SwiftUI app.
  - The status item and panel.
  - The details and settings windows.
  - Notifications.
  - Login item (`SMAppService`). It asks once, and only when launched from
    `/Applications`.
- `Tests/WatcherCoreTests`: Swift Testing. `WatchTests` drives the real
  `Watch` through simulated minutes of network behavior, with no mocks. Each
  test exists because the behavior it checks broke, or could break, in a way
  that matters. Before adding a test, check that it fails when the behavior it
  names is broken.

## Building and running

- `make test`: runs the tests.
- `make app`: builds `build/TheWatcher.app`, signed ad hoc for this Mac only.
- `make run`: builds the app and opens it from the build folder.
- `make install`: builds the app, then replaces and opens
  `/Applications/TheWatcher.app`.

Light changes and path discoveries are logged under the subsystem
`local.thewatcher.TheWatcher`:
`/usr/bin/log show --last 1h --predicate 'subsystem == "local.thewatcher.TheWatcher"'`.

The app supports IPv4 only and requires macOS 26.

## Appendix: alternatives considered

- **jedisct1/pingbar.** Its code was safe to run if built from source, but it
  doesn't fit the need:
  - It probes with HTTPS HEAD requests, and TCP's resends hide packet loss as
    latency.
  - It keeps only the last 30 results in memory.
  - It has no timeline.
  - About half of it is a DNS switcher.
- **One ping a second to a far host, all the time.** This was rejected out of
  respect for the hosts. Reading the kernel's TCP statistics catches the
  burps you actually feel, at zero network cost.
- **Running `nettop` as a subprocess.** This was rejected in favor of talking
  to the same kernel interface directly.
- **Fixed latency thresholds.** These were rejected because a satellite link
  and a fiber link need different ideas of "slow".
- **Wi-Fi name as the place fingerprint.** This needs Location permission. The
  router's hardware address doesn't.
- **Re-tracing the route on a timer.** The near stops change only with the
  network, and the internet hosts are pinged directly, so routing changes in
  between don't matter.
- **A separate color, or a history strip, for burps.** A single dot was chosen
  to keep it simple. Yellow carries "recent but cleared".
- **A floating dot or a desktop widget.** A floating dot appears on only one
  screen. Widgets get covered by windows and can't refresh live. The menu bar
  appears on every display. A floating dot remains an option if the menu bar
  overflowing behind the camera notch becomes a problem.
- **Fallback machinery for losing kernel-statistics access.** This was deferred
  on purpose and will be handled if it happens. The pings work without it.
