---
date: 2026-10-30 12:00:00 +0000
title: "False friends: finding bugs by porting a library"
---

In [the first post](/2026/10/30/go-has-no-undefined.html), I described how I'm learning Go: porting the helpers from Qlik's TypeScript library, [@qlik/api](https://github.com/qlik-oss/qlik-api-ts), onto [my fork](https://github.com/CatWithEyebrows/enigma-go) of [enigma-go](https://github.com/qlik-oss/enigma-go), Qlik's Go client. 

Anyone who has learned a second language knows "false friends": words that look like a word you know but mean something else. The Portuguese *pretender* means "to intend", not "to pretend". You only catch them by checking, and it pays off twice: you learn a new word, and you look at the one you knew a little more carefully.

Porting code has false friends too. A piece of JavaScript looks like it translates directly into Go, you write the Go version, and the two turn out to disagree. Sometimes the version you wrote is wrong. But sometimes the original one is.

The last step of my method is: when the Go version has to work differently, find out why before deciding which one is right. This post covers two parts of the port where that step turned up actual bugs in `@qlik/api`, and one where it didn't.

## Undo groups

`@qlik/api` can group several changes into one undo step: change three properties, and a single undo reverts all three. The engine has no concept of this. The library builds it from two things the engine *does* have: an undo buffer, and a session object whose properties hold a list of "markers".

Starting or ending a group adds a marker. Changing a session object's properties is **itself** an undo step, so undoing past the start of a group **removes its marker again**. That gives a simple rule: while the number of markers is **odd**, *you're inside a group*, so undo and redo keep going until it's **even** again.

Before porting any of it, I checked on a real tenant that the engine really puts session object property changes on the undo stack (after all, the whole design depends on it) and it does.

Then I ported it, and found three false friends.

### Redo checks the wrong layout

In JavaScript, `redo()` is a chain of promises: redo, then fetch the object's layout, then count the markers. Simplified:

```js
// layout was fetched before the redo
return app.redo().then(() => model.getLayout().then(() => {
    evenMarkers = layout.markers.length % 2 === 0;
```

The inner callback doesn't take the fresh layout as a parameter, so `layout` still refers to the one fetched *before* the redo. `undo()` gets this right by naming the parameter.

Go code is written step by step instead of as nested callbacks, so in my version the two layouts sit right next to each other:

```go
layout, err := undo.layout(ctx)   // before the redo
...
if _, err := undo.doc.Redo(ctx); err != nil {
    return err
}
if layout, err = undo.layout(ctx); err != nil {   // after the redo
    return err
}
if len(layout.Markers)%2 == 0 {
    return nil
}
```

Go doesn't make the bug *impossible*. But writing it this way, you can't avoid deciding which layout you mean, and that question led me back to the JavaScript. A unit test with a small fake undo buffer confirmed the effect: say a value is set to 1, then to 2 *and* 3 inside a group, then to 4. Undo twice, and you're back at 1. Good. Now, redo: nothing visibly happens, because only the group's **start marker** was redone. Redo again, and the value jumps straight to 4, skipping 3.

Where you'd notice: say a mashup has an "Apply theme" button that changes several chart properties as one undo step.

```js
const undoInfo = await app.getUndoInfoObject();
const group = await undoInfo.startGroup();
await chart.setProperties({ ...props, color: newColor, title: newTitle });
await undoInfo.endGroup(group);
```

The user clicks Undo, then Redo, and nothing happens. They click Redo again, and they land past the theme, on whatever change came after it.

### One group for every app

The JavaScript keeps the open group's id in a variable at the top of the module. In JavaScript that looks harmless.

In Go, the equivalent is a package-level variable, and that's an obvious warning sign, because a Go program routinely has many app sessions open at once. Porting it meant deciding where the state should live, and the answer is: on each app's undo object. Which raised the question of what happens in `@qlik/api` with two apps. If app B starts and ends a group while app A has one open, B overwrites A's group id. A's group never closes, and every later undo in A goes back to where that group started.

Where you'd notice: a script that restyles several apps at once, which is exactly the kind of thing that's normal in Go.

```js
// applyTheme groups each app's changes, like the button above
await Promise.all(apps.map((app) => applyTheme(app)));
```

The groups overlap in time and share one "current group" variable, so some of them never close. Later, an undo in one of those apps goes back much further than the user expects.

### One failure stops everything

The JavaScript makes undo and redo calls wait their turn in a **queue of promises**. In Go, the natural replacement is a mutex, a lock that one call holds at a time:

```go
undo.state.mutex.Lock()
defer undo.state.mutex.Unlock()
```

`defer` releases the lock when the function returns, whether it succeeded or failed. Writing that line made me ask what the JavaScript queue does on failure. It only removes a call from the queue when the call succeeds. After one failed undo (e.g., an aborted request), every later undo and redo fails with that same *old* error, without ever reaching the engine. Because the queue is module-level too, that includes other apps.

All three reproduce with `@qlik/api`'s published code, and I've [raised the issue](https://github.com/qlik-oss/qlik-api-ts/issues/205).

## Creating sheets, stories and master items

`@qlik/api` has helpers to create sheets, stories and master visualizations with the properties the Qlik Sense client expects. Their options are documented in JSDoc comments.

In Go, I gave each helper an options struct, with one named, typed field per documented option:

```go
type SheetOptions struct {
    ID             string
    Title          string
    Description    string
    Thumbnail      string
    Rank           *float64
    Columns        int
    Rows           int
    CustomRowBase  int
    GridResolution string
    // ...
}
```

To fill in each field, I had to trace every documented option to where the JavaScript uses it. Four of them didn't line up:

- **No options crashes.** In Go, a struct always has a valid empty value, so "no options" is a normal case with a test of its own. In JavaScript, `createSheet()` and `createStory()` document their options as optional, but read `props.title` straight away and throw.
- **A story's description is dropped.** `Description` needed somewhere to go, and the JavaScript never reads it: stories are always created with an empty description.
- **`customRowBase` is read from the wrong option.** Mapping `CustomRowBase` led to the line that sets it from `rows` instead.
- **Tags are a string.** `Tags []string` can't default to `""` in Go: that doesn't compile. In JavaScript, `tags: props.tags || ""` works fine until someone loops over the tags of a master item created this way.

The tags one shows how a small bug lands on someone else, later. Say one script builds an app's master items without tags. Months later, a governance script marks every master item as reviewed:

```js
props.qMetaDef.tags.push("reviewed");   // TypeError: push is not a function, tags is ""
```

The error is in the *second* script, but the cause is in the *first*.

All of them reproduce with `@qlik/api` itself, including the latest release, and I've [raised these too](https://github.com/qlik-oss/qlik-api-ts/issues/206).

## The one that wasn't a bug

There was a fifth suspect. The engine's type for a sheet's thumbnail is an object with a `qUrl` field, and `@qlik/api` passes a plain string instead. It looked like the same kind of mismatch as the tags.

Before writing it up, I tested it on the tenant. The engine accepts the plain string and stores it as `{qUrl: ...}`, exactly as if it had been given the object. Not a bug.

That's the other half of false friends: sometimes the word you were suspicious of means exactly what you thought. Translating code shows you where two versions differ. Only the real system can tell you which differences matter, so every finding in this post was checked against a real tenant, with `@qlik/api`'s own code, before I raised it as an issue.

## What I'm taking from this

The port forced a decision at every place the two languages disagree, and each decision meant reading the JavaScript closely enough to know what it really does. That's a slower kind of reading than a code review, and it finds things that are easy to read past.

The fork has all of these fixed, with unit tests against a fake engine and integration tests against a real one.

**The next post** is about a bug the port found in enigma-go itself, which Go's race detector flagged the first time I ran the tests. It had been there since the library's first commit.
