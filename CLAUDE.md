Don't (declare 'atstrings nil). Instead, escape @ symbols inside strings by doubling (e.g. "foo@bar.com" becomes "foo@@bar.com".)

Instead of (foo 'bar), use ! syntax (i.e. foo!bar)

Bracket-lambda gotcha: `[_!dead]` expands to `(fn (_) (_!dead))` = `(fn (_) ((_ 'dead)))` which calls the result. Need `[_ 'dead]`.

Instead of:

```
(let user (fetch-user id)
  (when user
    ...))
```

you can use arc's `whenlet`:

```
(whenlet user (fetch-user id)
  ...)
```

