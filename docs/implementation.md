# chartMaker - Implementation

**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**[Design](design/readme.md)** --
**Implementation** --
**[Deployment](deployment.md)**

Where [Design](design/readme.md) describes the structures, this document describes the code
that implements them: how the modules are layered, what the application exposes over HTTP,
and where it runs more than one thread. Where its files live is
[Deployment](deployment.md).

## The modules are layered, and the layering is a rule

Four prefixes, and they are a dependency order rather than a filing system: a module may use
anything above it and nothing below.

| Prefix | Layer | Holds |
| ------ | ----- | ----- |
| `cm_`  | foundations | constants, preferences, folder resolution, the state counter, the per-set build configuration |
| `dm_`  | the model and the work | regions, sources, the cache, coverage, fetch, fill, analysis, the build act, and one module per exporter |
| `em_`  | the doors in | the command vocabulary and its dispatcher, the console, the HTTP server |
| `w_`, `win` | wx | the frame, the dialogs, and the two trees |

`chartMaker.pm` sits above all of it as the entry point.

**Everything above `w_` must load and run with no wx at all.** That is the rule that keeps
the layering honest, and it is worth more than tidiness: it is what lets the whole model,
the whole build and the whole analysis be exercised headlessly, and it is why a defect in a
dialog is the only kind that needs a person in front of a screen.

**`dm_` holds no control flow of its own.** `dm_fetch` retrieves one tile from one source
and reports bytes or a definite absence; deciding *when* to ask belongs above it.

The module list itself is the source tree, which is always right about what is there. What
cannot be read off a directory listing is the rule above.

## The HTTP Surface

The embedded server answers two unrelated audiences, and they are kept apart on purpose.

**`/api/...` is the drive surface.** It is the console vocabulary exposed over HTTP - what
a developer calls by hand, what a test harness calls, and what makes a running chartMaker
inspectable from outside. It is stable, because things outside the application depend on
it.

**Everything else is the applet's own protocol.** These paths are a private contract
between the server and the JavaScript in `_res/site`, and they change whenever the applet
changes. Nothing outside the application should depend on them.

| Path                      | Surface | Purpose                                        |
| ------------------------- | ------- | ---------------------------------------------- |
| `/api/command?cmd=<cmd>`  | drive   | Dispatch a command through `em_command`.       |
| `/api/log?since=<seq>`    | drive   | Output-ring entries since a point.             |
| `/poll`                   | applet  | A cheap version probe.                         |
| `/state`                  | applet  | Everything currently visible, as one document. |
| `/coverage?z&w&s&e&n`     | applet  | Tiles in coverage at one zoom, in view.        |
| `/preview?z&w&s&e&n`      | applet  | The same tiles, each named with the source it would be built from. |
| `/counts?id=<id>`         | applet  | Tiles and bytes by level, for the set and the chain down to one object. |
| `/tile/<src>/<z>/<x>/<y>` | applet  | The tile proxy.                                |
| `/edit`                   | applet  | A model mutation carrying structured data.     |

### The poll protocol

The application holds the truth; the browser renders it and asks for changes. `/poll`
returns a version number, and the client refetches `/state` when that number differs from
what it last rendered.

**One version counter, one state document.** The visible regions, the source list, the
active source, an evaluator result - all of it arrives together, so no two parts of the
display can be out of step with one another. The temptation to add a second channel for one
more kind of update is the thing to resist.

**A second counter says whether the MODEL moved, and it is published to nobody.** Selecting
an object and entering an edit both change what should be on screen, so both bump the poll
counter - and neither moves a polygon, so anything derived from the geometry is still valid
across them. Coverage costs about a second for a set; keyed on the poll counter, that work
was thrown away by every click in the tree. The default is the safe one: a mutation that
says nothing bumps both, which is merely slow, where the opposite default would serve a
stale answer.

**`/poll` also records when it was last asked.** One timestamp, no session - see
[Tree Editing](design/editing_tree.md). It answers whether a browser is there, which is what
lets an edit left behind by a closed window be cleared instead of blocking the tree forever.

Three properties of the protocol are worth stating because each is easy to lose:

- **The server has no notion of a connected browser.** It answers questions. That is what
  makes closing and reopening the browser a non-event, with no session to clean up.
- **Reconnect is client-owned.** Every fetch carries a short timeout; on failure the client
  clears its layers and resets its last-rendered version, so the next successful poll sees a
  mismatch and resyncs everything.
- **The render loop must yield.** JavaScript is single-threaded, so a long render blocks
  the poll timer. Rendering in chunks with a yield between them is what keeps the
  connection alive under load - it looks like an optimisation and is actually a
  correctness requirement.

### Mutations and the applet

The applet edits geometry, so `/edit` carries structured data rather than a command line -
a polygon does not fit in a query string. It **dispatches into the same `em_command`
vocabulary** as the console and `/api/command`, which is what keeps the "anything one door
can do, the others can" property true even for the one operation only the map can perform.

That requires the dispatcher to accept an optional structured payload alongside the verb
and its text arguments. The console passes none.

One applet-side rule follows from the poll loop: **an object being edited leaves the
poll-rendered layer.** While a polygon is under the user's hand it is rendered from local
state and skipped by the renderer; on commit the edit is sent, the version advances, and
the application's copy becomes the truth again. Without that, the poll would deliver the
old geometry back mid-drag and fight the user.

## Threads, and why nothing calls back

chartMaker runs the HTTP server and the console on their own threads, and the build on a
third. One rule covers all of them: **a callback firing on another thread must not touch a
wx widget**, so nothing calls back and every surface asks instead.

**Nothing observes; everything polls a counter.** Keeping the native panes and the browser
agreeing about what is checked looks like a job for an observer, and it is not one. The
state version counter already does it: both wx panes poll it on a timer, the browser polls
it over HTTP, and a change made anywhere is picked up everywhere on the next tick. An
observer would have to hop threads to be safe, which is a queue and a timer wearing a
different name.

**The model travels between threads as a document.** Each thread holds its own copy and
refills from the published document when the shared counter moves - from the document rather
than from disk, because with a set open the disk no longer holds what the user is looking
at.

**The build is a detached worker carrying a shared record**, and the alternative worth
recording is that it could have been a separate process. The worker writes counters and
reads a cancel flag; the dialog reads counters and writes the cancel flag; nothing else
crosses in either direction. See [Build](design/build.md#progress-and-where-the-build-runs).

**It is the one thread spawned after wx exists.** The server and console threads are created
before the application object, deliberately, so they inherit a loaded model and copy an
interpreter with no widgets in it. A worker launched from a menu cannot do that. There is
precedent outside this application - the same shared-record-and-detached-worker shape drives
a card write from navMate's GUI - and none inside it, which is the reason to say so here.

**Fetch and build are one piece of machinery.** They differ only in which function the
worker calls and what the report says; building it twice is how the two end up behaving
differently.

---

**Next:** [Deployment](deployment.md)
