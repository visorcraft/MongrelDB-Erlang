# Authentication & Authorization

A `mongreldb-server` daemon runs in one of three modes:

1. **Open** (default) - no auth required.
2. **Bearer token** (`--auth-token <TOKEN>`) - every request must carry an
   `Authorization: Bearer <TOKEN>` header.
3. **HTTP Basic** (`--auth-users`) - every request must carry an
   `Authorization: Basic <base64(user:pass)>` header.

The Erlang client supports all three through `mongreldb:connect/1` options. This
guide shows each mode, how to inspect what was sent, and how to manage users
and roles via SQL when the server is in Basic mode.

---

## Bearer token mode

Start the daemon with a token:

```sh
mongreldb-server --auth-token s3cret-token
```

Connect with `token`. The token is sent as `Authorization: Bearer ...` on
every request.

```erlang
{ok, Db} = mongreldb:connect(#{url => <<"http://127.0.0.1:8453">>,
                               token => <<"s3cret-token">>}),

case (catch mongreldb:health(Db)) of
    true -> io:format("healthy~n", []);
    {mongreldb_error, mongreldb_auth_error, _} -> erlang:error(bad_or_missing_token);
    false -> erlang:error(daemon_unreachable)
end.
```

A missing or wrong token surfaces as `mongreldb_auth_error` (HTTP 401/403).

### Where the token comes from

Hard-coding secrets in source is bad practice. Read it from the environment:

```erlang
Token = case os:getenv("MONGRELDB_TOKEN") of
            false -> erlang:error(missing_mongreldb_token);
            "" -> erlang:error(missing_mongreldb_token);
            V -> list_to_binary(V)
        end,
{ok, Db} = mongreldb:connect(#{token => Token}).
```

## Basic auth mode

Start the daemon with a users file or inline users:

```sh
mongreldb-server --auth-users
```

Connect with `username` / `password`:

```erlang
{ok, Db} = mongreldb:connect(#{url => <<"http://127.0.0.1:8453">>,
                               username => <<"admin">>,
                               password => <<"s3cret">>}).
```

The client base64-encodes `username:password` and sets
`Authorization: Basic ...` on every request.

## Token takes precedence

If you supply both, `token` wins and Basic credentials are ignored. This lets
you layer an override without branching:

```erlang
{ok, Db} = mongreldb:connect(#{url => Url,
                               username => <<"fallback">>,
                               password => <<"user">>,
                               token => <<"overrides-everything">>}).
```

## Timeouts

The client takes `timeout` (per-request) and `connect_timeout`, both in
milliseconds.

```erlang
{ok, Db} = mongreldb:connect(#{url => Url,
                               token => Token,
                               timeout => 10000,
                               connect_timeout => 30000}).
```

## User and role management via SQL

When the daemon is in Basic auth mode, users and roles live in the catalog and
are managed with SQL. Run these statements through `mongreldb:sql/2`.

### Create a user

```erlang
{ok, _} = mongreldb:sql(Db, <<"CREATE USER alice WITH PASSWORD 'hunter2'">>).
```

### Alter a user

Change a password:

```erlang
{ok, _} = mongreldb:sql(Db, <<"ALTER USER alice WITH PASSWORD 'new-password'">>).
```

Grant the admin role:

```erlang
{ok, _} = mongreldb:sql(Db, <<"ALTER USER alice ADMIN">>).
```

`ALTER USER ... ADMIN` is how you promote a user to full administrative
privileges (table creation/drop, compaction, user management). Use it
sparingly.

### Drop a user

```erlang
{ok, _} = mongreldb:sql(Db, <<"DROP USER alice">>).
```

### Roles and grants

```erlang
{ok, _} = mongreldb:sql(Db, <<"CREATE ROLE analyst">>),
{ok, _} = mongreldb:sql(Db, <<"GRANT SELECT ON orders TO analyst">>),
{ok, _} = mongreldb:sql(Db, <<"GRANT analyst TO alice">>),
{ok, _} = mongreldb:sql(Db, <<"REVOKE SELECT ON orders FROM analyst">>),
{ok, _} = mongreldb:sql(Db, <<"DROP ROLE analyst">>).
```

Exact grant syntax mirrors the server's SQL flavor; consult the server's SQL
reference for the full `GRANT`/`REVOKE` grammar available in your build.

## Common pitfalls

**Auth errors look like other errors without a specific catch clause.** A
401/403 raises `mongreldb_auth_error`; a 404 raises
`mongreldb_not_found_error`. Always discriminate by class rather than
string-matching the message.

**Forgetting to set auth in production.** A client built with
`mongreldb:connect/0` and no credentials sends no credentials. Against an
auth-enabled daemon, every call raises `mongreldb_auth_error`. Centralize
client construction so the auth option is never accidentally dropped.

**Sharing one client across processes is fine; sharing credentials across
users is not.** A client is a plain map and safe for concurrent use, but it
carries one identity. If you serve multiple authenticated users, build a client
per user (or per request) with that user's token.

**Token in version control.** Put secrets in the environment, a secret
manager, or a file outside the repo. Never commit a real token.

## Next steps

- [errors.md](errors.md) - `mongreldb_auth_error` and the rest of the error hierarchy
- [quickstart.md](quickstart.md) - the full end-to-end walkthrough
