---
date: 2026-11-10 00:00:00 -0300
title: "Whose goroutine is this? A grammar JavaScript doesn't have"
---

This series is about learning Go by porting the helpers from Qlik's TypeScript library, [@qlik/api](https://github.com/qlik-oss/qlik-api-ts), onto [my fork](https://github.com/CatWithEyebrows/enigma-go) of [enigma-go](https://github.com/qlik-oss/enigma-go), Qlik's Go client. The method borrows from learning spoken languages: use what you know to infer what you don't, then check whether the pattern makes sense. [The first post](/go-has-no-undefined/) covered what Go makes you write down. [The second](/false-friends/) covered the bugs that turned up where the JavaScript and the Go disagreed.

This one is about where the method stops working.

Some languages have grammar yours doesn't. If your first language has no grammatical cases, you can't infer German's from anything you know. You learn them from scratch, and you lean on a native speaker to tell you when you get them wrong.

For a JavaScript developer, **Go's concurrency** is that kind of grammar. JavaScript runs your code on a single thread, one callback at a time. Go runs many goroutines at the same time, and they can block each other. There's nothing in JavaScript to infer that from. Thankfully, Go ships with its own *"native speakers"*, and one of them helped me find a problem in enigma-go that has been there since its first commit in 2018.

## Watching an object

`@qlik/api` has `layoutSubscribe`: give it an object, and it calls you back with a fresh layout every time the object changes. A KPI that redraws when someone makes a selection is built on that.

The Go version, `WatchLayout`, is built on something enigma-go already had: `ChangedChannel`. It returns a Go channel that receives a signal every time the engine says the object changed. Before building on it, I read how it works. That meant reading the code with a question JavaScript never makes you ask: *which* goroutine runs this, and what is it *holding* while it does?

The signals are sent by `signalChanged`, which runs on the goroutine that **reads messages from the engine's websocket**. That goroutine is the *only way* any reply from the engine reaches your code. This is the original code:

```go
func (r *RemoteObject) ChangedChannel() chan struct{} {
	channel := make(chan struct{}, 16)
	r.changedChannels[channel] = true
	return channel
}

func (r *RemoteObject) signalChanged() {
	r.mutex.Lock()
	for channel := range r.changedChannels {
		channel <- struct{}{}
	}
	r.mutex.Unlock()
}
```

Two things stood out:

1. **`ChangedChannel` changes the list of channels without taking the lock.** Every other function that touches that list takes it first. If your code asks for a channel while a change notification arrives, two goroutines touch the same map at the same time. In Go, that can crash the whole program.
2. **`channel <- struct{}{}` waits when the channel is full.** Each channel holds 16 signals. If nobody reads one, the 17th send waits until someone does, and it waits on the goroutine that reads the websocket.

## Asking the native speakers

Reading the code gave me two suspicions. Go has two tools that can confirm or rule them out.

**The race detector.** Run tests with `go test -race`, and Go watches every memory access while they run. When two goroutines touch the same memory without coordinating, it reports a `DATA RACE`, with the code on both sides. I wrote a test that asks for channels while change notifications arrive, and the race detector flagged it on the first run.

**Tests that expect something to finish.** A test that sends more signals than the channel holds, with nobody reading, and fails if the sends don't finish within a second. It failed: `signalChanged blocked on a full channel`.

Then I checked that it wasn't just my fork, by running both tests on a clean copy of Qlik's current enigma-go. The race test didn't just *fail* there: it hung until the test timed out. Go then prints what every goroutine was doing at that moment (the goroutine dump) and that showed a *third* way in. `signalChanged` was stuck sending to a full channel while holding the lock. The test was trying to unregister that channel with `RemoveChangeChannel`, which needs the same lock. Each was waiting for the other, forever.

## Where you'd hit it

One more check before calling it a real-world problem: I tested how the engine sends change notifications. When an object changes several times and nobody fetches its layout in between, the engine sends **one** notification, not one *per change*. So a single reader that fetches the layout after each signal can never fill its own channel.

Two readers can. Say a program watches a KPI in two places:

```go
kpi, _ := doc.GetObject(ctx, "sales-kpi")

// A dashboard redraws the KPI on every change
go func() {
	for range kpi.ChangedChannel() {
		layout, _ := kpi.GetLayout(ctx)
		render(layout)
	}
}()

// An audit log records the changes, but gives up at its first error
go func() {
	for range kpi.ChangedChannel() {
		if err := logChange(); err != nil {
			return // stops reading, and never unregisters its channel
		}
	}
}()
```

After the audit log stops, the dashboard keeps fetching the layout, so every selection sends a new notification, and nobody reads the audit log's channel. Sixteen selections later it's full. On the seventeenth, the goroutine that reads the websocket waits to send a signal nobody will ever read.

From then on, no reply from the engine reaches the program: not the dashboard's `GetLayout`, not the next selection, *nothing*. There's no error and no crash. The program just stops. And if the audit log does the right thing on its way out, `defer kpi.RemoveChangeChannel(ch)`, it can hang just the same, through the lock, as the goroutine dump showed.

On my tenant, an unread channel next to a reader that fetches after every selection got exactly 16 notifications for 20 selections: a full buffer. In the original code, the next one would have stopped the session.

## The fix

Two small changes. Take the lock in `ChangedChannel`, and never wait in `signalChanged`:

```go
for channel := range r.changedChannels {
	// Never block, this runs on the goroutine that reads from the socket
	select {
	case channel <- struct{}{}:
	default:
	}
}
```

`select` with a `default` case sends if there's room and skips if there isn't. Skipping loses nothing: a full channel already holds 16 signals that all mean "this object changed", and a 17th says nothing new. With that, both tests pass, and so does the rest of the test suite under the race detector.

It's fixed in the fork, and I've [raised it](https://github.com/qlik-oss/enigma-go/issues/355) on enigma-go.

## What I'm taking from this

Inferring from what you know only works when there's something to infer from. JavaScript's single thread means a whole class of problem (two pieces of code getting in each other's way at the same moment) mostly doesn't come up, so I had no instinct for it in Go. The question that found this one, "whose goroutine is this?", is one I'd never had a reason to ask before.

To continue the analogy, the race detector and the goroutine dump are the native speakers: they may not know the *why* to explain the grammar, but they tell you **exactly** where you got it wrong, so you don't learn patterns that aren't there. The engine itself was the last check, the same as in the previous posts: the real system decides whether a problem in the code is a problem in practice.

---
At some point, you have to start speaking the language out in the real world. **Next on my list**: benchmarking the fork against `@qlik/api` in some interesting scenarios. 
