# clarc

An Arc-to-Common-Lisp port of [Arc](http://arclanguage.org/) and the
News web app that powers [Hacker News](https://news.ycombinator.com).

In September 2024, Hacker News migrated from Arc-on-Racket to Arc on
[SBCL](http://www.sbcl.org/) using a compiler called *Clarc* that dang
had been developing for years. The port lets HN run on multiple cores
and was fast enough to retire pagination on long threads. See the
[announcement thread](https://news.ycombinator.com/item?id=44099006)
and Vincent Massol's [write-up](https://lisp-journey.gitlab.io/blog/hacker-news-now-runs-on-top-of-common-lisp/).

This repository is an independent open-source Arc-on-Common-Lisp
runtime in the same spirit. It boots `arc0.lisp` (a port of Arc's
`ac.scm`) under SBCL and then loads `arc.arc` and the rest of Arc on
top of it, so News and other Arc programs run unmodified.

## Requirements

You'll need [SBCL](http://www.sbcl.org/) installed (`brew install sbcl`
on macOS, `apt install sbcl` on Debian/Ubuntu).

## Running the tests

```sh
./test.arc
```

`test.arc` is adapted from [lumen](https://github.com/sctb/lumen)'s
test suite plus extra cases added during the port. A clean run prints
something like `193 passed, 0 failed`.

## Running News

```sh
mkdir -p arc
echo "myname" > arc/admins
./clarc
```

At the arc prompt:

```
arc> (load "news.arc")
arc> (nsv)
```

Go to [http://localhost:8080](http://localhost:8080).

Click on login and create an account called `myname`. You should now
be logged in as an admin. Manually give at least 10 karma to your
initial set of users.

Don't worry about "user break" messages when restarting News.

## Customizing News

Change the variables at the top of `news.arc`.

## Performance tuning

```arc
(= static-max-age* 7200)    ; browsers can cache static files for 7200 sec

(declare 'direct-calls t)   ; you promise not to redefine fns as tables

(declare 'explicit-flush t) ; you take responsibility for flushing output
                            ; (all existing news code already does)
```

## Layout

- `arc0.lisp` — Arc runtime for Common Lisp (port of `ac.scm`)
- `clarc` — shell launcher that boots SBCL with `arc0.lisp`
- `arc.arc`, `libs.arc`, `strings.arc`, `code.arc`, `html.arc`,
  `pprint.arc`, `srv.arc`, `app.arc`, `prompt.arc` — Arc itself,
  built on top of `arc0`
- `news.arc`, `blog.arc` — the News and Blog applications
- `static/` — static assets served by `srv.arc`
- `test.arc` — Arc test suite

## Development history

The port was built incrementally; each step is recorded as a
[handoff](https://news.ycombinator.com/item?id=47581897) note in
[`docs/agents/handoff/`](docs/agents/handoff/), starting with
[`2026-04-25-001-arc0-port.md`](docs/agents/handoff/2026-04-25-001-arc0-port.md).
Read those in order if you want to see how arc0 was bootstrapped, what
broke along the way, and how each fix was reasoned through.

## License

Copyright (c) Paul Graham and Robert Morris. Released under the MIT
License with Paul Graham's permission. See [copyright](copyright).
