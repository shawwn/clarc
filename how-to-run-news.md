# To run News

You'll need [SBCL](http://www.sbcl.org/) installed (`brew install sbcl`
on macOS, `apt install sbcl` on Debian/Ubuntu).

```sh
mkdir -p arc
echo "myname" > arc/admins
./sharc
```

At the arc prompt:

```
arc> (load "news.arc")
arc> (nsv)
```

Then go to http://localhost:8080

Click on login, and create an account called `myname`.

You should now be logged in as an admin.

Manually give at least 10 karma to your initial set of users.

# To customize News

Change the variables at the top of `news.arc`.

# To improve performance

```arc
(= static-max-age* 7200)    ; browsers can cache static files for 7200 sec

(declare 'direct-calls t)   ; you promise not to redefine fns as tables

(declare 'explicit-flush t) ; you take responsibility for flushing output
                            ; (all existing news code already does)
```
