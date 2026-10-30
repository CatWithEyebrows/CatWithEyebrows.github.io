---
title: "Go has no undefined: learning a language by porting what I know"
---

I'm dipping my toes in Go, using something I know inside out: the Qlik engine API. Qlik's Go client, [enigma-go](https://github.com/qlik-oss/enigma-go), covers the raw engine API. Their TypeScript library, [@qlik/api](https://github.com/qlik-oss/qlik-api-ts), adds a layer of helpers on top: typed lists of sheets and fields, undo groups, layout subscriptions, creating sheets and stories. I'm porting those helpers to Go, in [my fork of enigma-go](https://github.com/CatWithEyebrows/enigma-go).

## Learning a language when code gets generated

Generating code is the norm now. I work using AI assistants, producing more patterns than I could ever hold in my head. That makes it tempting to experiment in languages I have less experience with. The catch is the learning: how do you come out of it understanding something, instead of just owning code you didn't write?

For a coding language, I figured the best approach is the one that works for spoken languages: use what I know to **infer what I don't**, then check whether the pattern **makes sense** (it's more complicated than that, but that's the idea). Here, what I know is the Qlik engine and the JavaScript library. The Go is new. My part is checking that every translated pattern still means what it meant in JavaScript.

That turns porting into a code review you can't skim. You can't copy JavaScript into Go line by line: `@qlik/api` builds its helpers as about thirty small "mixins" patched onto engine objects at runtime, and *Go doesn't do that*. Every helper gets rewritten, and every rewrite has to be checked against the original and against the engine.

The interesting moments are where a JavaScript pattern has no direct equivalent in Go. Go asks questions that JavaScript patterns let you skip. Here are five of them, from the first step of the port, the list helpers.

## 1. Go has no `undefined`

In JavaScript, if you don't need an argument, you leave it out and it isn't sent. Go has no `undefined` and no optional arguments, so "nothing" has to be one specific value. For a list, that's `nil`, and Go's JSON encoder turns a `nil` slice into `null`.

The engine doesn't accept that:

```go
// labels isn't needed here, so nil is the natural thing to pass
msg, _, _, err := doc.CheckExpression(ctx, "Sum(Sales)", nil, false)
// err: a JSON parse error from the engine
```

The obvious fix was to send empty values instead: `[]` for lists, `{}` for objects. That fixed this case and broke another. `CreateChild` takes optional new properties for the parent object. `null` there means "leave the parent alone", and `{}` means "replace the parent's properties with nothing", which the engine refuses, after it has already created the child.

So I had generalized from two examples and been wrong. Instead of guessing a third time, and since I can, why not test all 101 array and object parameters in the engine API against a real tenant? With `null`, with an empty value, and left out. The result:

- Every array parameter rejects `null`, and `[]` works the same as leaving it out.
- Optional object parameters split both ways: some accept `null` and reject `{}`, others the other way round.
- Leaving the parameter out works for all of them.

So the fork now sends `[]` for a `nil` list, and leaves out trailing optional parameters that are `nil`. That's the closest Go gets to JavaScript's "just don't pass it".

## 2. Go has no optional parameters

The same gap shows up from the other side. The engine API grows over time, often by adding an optional parameter to an existing method. In TypeScript, that's invisible to callers. In Go, the method's signature changes and every caller stops compiling. When I regenerated enigma-go from the current engine spec, `CheckExpression` gained a `strictFieldValidation` parameter, and that's exactly what happened.

So the fork records how many parameters each method takes today, keeps those signatures fixed, and puts any parameters added later into a `<Method>WithOptions` variant with an options struct. That design raised the question from point 1 straight away: what do you send for an option the caller didn't set? Without the 101-parameter test, I'd have picked the wrong answer for some of them.

## 3. Errors are values

A Go function that can fail returns an error next to its result, and the caller has to deal with it. So when I wrote `GetOrCreateSessionObject` (get a session object by its id, or create it if it isn't there), I needed to know what "not there" looks like.

Ask the engine for an object id that doesn't exist, and it answers successfully with a null type and a null handle. That's fine. enigma-go turned that into an object pointing at handle 0, so every call on it went to whatever handle 0 is. It also cached that object, so every later lookup of an unknown id returned **the same one**.

In JavaScript, a result like that flows through until something downstream happens to look at it. In Go, I had to write the "not found" branch, which meant finding out what not found actually is. The fork now returns `ErrObjectNotFound` from the 38 methods that return engine objects, so callers can check for it with `errors.Is`.

## 4. JSON has to fit the type

In the port, each list item is a Go struct, so a sheet's title is a `string` and its `cells` are a slice. Decoding JSON into a struct is strict: if the engine sends a string where the struct expects a boolean or a slice, decoding fails.

That's how I found out that when a list asks for a property an object doesn't have, the engine returns `""` for it, whatever type it should be: a missing boolean comes back as `""`, and so does a missing list. In JavaScript, that becomes an empty string where an array should be, and nothing complains... *until someone loops over it*. In Go, the first test failed. The fork now decodes those values as Go's zero values: `false`, an empty list, and so on.

## 5. Tests that say what they expect

`GetOrCreateSessionObject` has a test that calls it five times in parallel with the same id and expects exactly one object. It got several.

When the id you ask for is already taken, the **engine** doesn't fail: **it creates the object anyway**, under a *random id*. That holds for session objects, generic objects, dimensions, measures, bookmarks and child objects. Variables are the exception, those do fail on a duplicate name.

I left the existing methods alone, since code may rely on that fallback (a port is only as good as its backwards compatibility). The fork adds `...WithID` variants (`CreateSessionObjectWithID`, `CreateDimensionWithID`, and so on) that return `ErrIDTaken` instead (and clean up the duplicate).

## What I'm taking from this

None of these are bugs in the JavaScript. JavaScript tolerates them: an argument that's left out, a value of the wrong type, a result that looks like success. Go doesn't, so I had to decide what each one should mean, and to decide that I first had to find out what the engine actually does.

That's the language-learning idea at work. The patterns that transferred cleanly taught me Go syntax. The ones that didn't transfer taught me the most, about Go and about an engine I thought *I already knew*.

So, this approach has turned into a method for the rest of the port:

1. Read the JavaScript, and note every behavior of the engine it relies on.
2. Check each of those behaviors on a real tenant before relying on it.
3. Port it, with a unit test against a fake engine and an integration test against a real one.
4. When the Go version has to work differently, find out why before deciding which one is right.

During the rest of the port, step 4 found actual bugs, and Go's race detector found a problem in enigma-go itself that goes back to its first commit.

**More on those in the next posts.**

---
The fork is at [github.com/CatWithEyebrows/enigma-go](https://github.com/CatWithEyebrows/enigma-go). 

Next on my list is benchmarking it against `@qlik/api` in some interesting scenarios.
