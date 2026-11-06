# Tasqs for unRAID

Turn unRAID notifications into tasks in [Tasqs](https://tasqs.com). A disk running hot becomes a task due today; when unRAID says it "returned to normal", the task completes itself. One script, no dependencies beyond what unRAID ships (`bash`, `curl`, `openssl`).

Requires a Tasqs **Premium** or **Power User** plan (webhooks).

## Install (five minutes)

1. **Create a webhook in Tasqs.** Profile → **Webhooks** → **Add webhook**. Name it after the server ("TOWER"), pick the list the tasks should land in, leave the defaults (priority follows the alert's level, due today, repeats ignored for 24 h, auto-resolve on). Press **Copy** to copy the URL.
2. **Put the script on the flash drive.** From the unRAID terminal (or any SSH session):
   ```bash
   mkdir -p /boot/config/plugins/dynamix/notifications/agents   # unRAID creates it only once an agent is enabled
   curl -fsSL https://raw.githubusercontent.com/tasqs-public/unraid-agent/main/Tasqs.sh \
     -o /boot/config/plugins/dynamix/notifications/agents/Tasqs.sh
   nano /boot/config/plugins/dynamix/notifications/agents/Tasqs.sh   # paste your webhook URL into HOOK=
   ```
   The agents folder lives on `/boot` (the USB flash drive), so the script survives reboots and unRAID upgrades. The drive is mounted `noexec`, so there is no `chmod +x` — unRAID runs agents through `bash`, and so should you.
3. **Tell unRAID which notifications to send.** Settings → **Notifications** → in the grid of importance levels, tick the **Custom** column for *Warning* and *Alert* (and *Notice* if you want everything). unRAID runs every script in the agents folder for the levels you ticked.
4. **Test it.**
   ```bash
   bash /boot/config/plugins/dynamix/notifications/agents/Tasqs.sh --test
   ```
   That sends a sample warning and then its all-clear: a task appears on your Tasqs dashboard and completes two seconds later. Profile → Webhooks → **Recent deliveries** shows both. Or trigger a real one: `/usr/local/emhttp/webGui/scripts/notify -e "Test" -s "Warning [TOWER] - Disk 3 is hot" -d "41 C" -i warning`.

## What a notification becomes

| unRAID | Task |
|---|---|
| Subject (`Warning [TOWER] - Disk 3 is hot (41 C)`) | Title, with the `Warning [TOWER] -` prefix removed |
| Description | Description, plus a footer *Added by webhook: TOWER* |
| Importance `normal` / `warning` / `alert` | Priority low / medium / high (or whatever the webhook's rules say) |
| Hostname | Source, shown in the footer |
| Link (newer unRAID builds) | A link line in the description |
| "…returned to normal", "…is back", "…finished" | **Completes** the task the earlier alert opened |

Repeats are handled by Tasqs: the same alert within the webhook's window (24 h by default) is skipped, so a disk that complains every minute makes one task, not sixty. The script also sends an idempotency key, so a retry after a timeout can never make a second task.

## Configuration

Everything is at the top of `Tasqs.sh`:

| Setting | Default | Meaning |
|---|---|---|
| `HOOK` | *(required)* | The webhook URL from Tasqs. |
| `SECRET` | empty | Fill in if you turned on **Require a signature** for the webhook. Every request is then HMAC-signed; a leaked URL alone can add nothing. |
| `LEVELS` | `normal warning alert` | A second filter on top of unRAID's Custom column, for a script shared between servers. |
| `KEY_MODE` | `stem` | What counts as "the same thing" for repeats and resolve: `stem` = event + the first two words of the subject (*Disk 3*), `event` = one open task per category, `full` = every distinct wording is its own task. |
| `RESOLVE_PATTERN` | *returned to normal, is back, finished, …* | Wording that means "resolved". |
| `TIMEOUT` | `10` | Seconds to wait for Tasqs (then two retries). |

Results go to the unRAID system log: `grep tasqs /var/log/syslog`. The webhook URL is never written to the log.

## Locking it down (optional)

- **Only from your server.** On the webhook's *Security options*, enter your public IP (or your VPN / Tailscale range). Deliveries from anywhere else are refused and show up as *Blocked by IP rule* in Recent deliveries.
- **Signed requests.** Turn on *Require a signature*, copy the secret Tasqs shows once into `SECRET=`. Requests are then signed with HMAC-SHA256 and time-stamped; anything older than five minutes is refused.
- Tasqs emails you the first time the webhook hears from a new address, and pauses the webhook by itself if a sender loops for a day.

## No script at all

If your unRAID build lists an **ntfy** agent on the Agents tab, that works without this script: server `https://tasqs.com/hook`, topic = the part of your webhook URL after `/hook/`. Importance maps through ntfy's priority. You lose only the auto-resolve, which needs the key this script derives.

## Development

`bash test/run.sh` runs 37 checks against a fake `curl` (key modes, prefix stripping, resolve detection, encoding, signing, exit codes). The server side of the contract is documented at [tasqs.com/api-documentation.php#webhooks](https://tasqs.com/api-documentation.php#webhooks).

## Licence

MIT — see `LICENSE`.
