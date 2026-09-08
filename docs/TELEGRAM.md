# Telegram notifications

One bot and one chat per server; enabled once, used by everything.

Settings > Telegram notifications asks for the bot token and the chat id
and sends a test message. `getbible.sh telegram enable|disable|test` does
the same from the command line. The configuration lives in
`/etc/getbible/telegram.conf`, readable by the `getbible-notify` group so
timers running as sync users can notify.

Every action that changes files on the server sends a message:

| Event | Message |
| --- | --- |
| sync | update started (repository, reference, commit); update live (commit, files, changed); failure with the step |
| endpoints | deployed, removed, access mode or limits changed, version added or removed |
| runtime | release live, readiness failure and rollback |
| certificates | issued (with the validation method), renewed (from certbot's deploy hook), failed |
| staging and go-live | endpoint staged; live (certificate, DNS outcome, verification); go-live failed at the certificate or at activation; staged again |
| tokens | issued (label), revoked (id) |
| log rotation | archive count per endpoint, warning at the retention ceiling |
| update | started, complete, or finished with failures |
| Cloudflare | DNS and rules applied, protected cache policy |

Messages carry the host name and a UTC timestamp. Delivery failures never
fail the action that triggered them.
