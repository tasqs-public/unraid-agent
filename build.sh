#!/usr/bin/env bash
# build.sh — generate the unRAID plugin files from the ONE script source.
#
#   plugin/Tasqs.xml   the Notification Agents template (Settings → Notifications
#                      → Agents → Tasqs). Same body as Tasqs.sh; its config block
#                      is replaced by unRAID's {0} marker + a mapping from the
#                      GUI fields to the script's variables.
#   plugin/tasqs.plg   the plugin manifest: keeps Tasqs.xml (and the icon) on the
#                      flash drive and copies them
#                      into unRAID's dynamix agents folder, on install and again
#                      at every boot (the root filesystem is rebuilt from the
#                      image). Downloads both from this repo's raw URLs, MD5-pinned,
#                      so the files committed here must be the bytes served.
#
# Run after every change to Tasqs.sh, commit the output. `bash test/run.sh`
# also builds and exercises the generated agent with {0} substituted.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/Tasqs.sh"
OUT="$HERE/plugin"
RAW='https://raw.githubusercontent.com/tasqs-public/unraid-agent/main'
VERSION=$(sed -n "s/^VERSION='\(.*\)'/\1/p" "$SRC")
PLG_VERSION=$(date -u +%Y.%m.%d)
mkdir -p "$OUT"

# ── Body = everything after the config block, with the test/version modes kept ──
body=$(awk '/^# ── End of configuration/{f=1; next} f' "$SRC")

cat > "$OUT/Tasqs.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
  <Agent>
    <Name>Tasqs</Name>
    <Variables>
      <Variable Help="In Tasqs go to Profile -> Webhooks -> Add webhook, name it after this server, pick the list its tasks should land in, and press Copy. Paste the URL here. Each server should have its own webhook (Premium or Power User plan). [a href='https://tasqs.com/guide.php#webhooks' target='_blank'][u]Guide[/u][/a]" Desc="Webhook URL" Default="https://tasqs.com/hook/tqh_PASTE_YOUR_WEBHOOK_URL">HOOK_URL</Variable>
      <Variable Help="Optional. If you turned on 'Require a signature' for the webhook, paste the secret Tasqs showed you. Every notification is then HMAC-signed and time-stamped, so the URL alone can add nothing even if it leaks. Leave 'none' otherwise." Desc="Signing secret" Default="none">SIGNING_SECRET</Variable>
      <Variable Help="How to decide that two notifications are the same thing, so Tasqs skips repeats and an all-clear (e.g. 'returned to normal') completes the task the warning opened. 'stem' = the event plus the first two words of the subject (Disk 3). 'event' = one open task per event type. 'full' = every distinct wording is its own task." Desc="Match repeats by" Default="stem">KEY_MODE</Variable>
      <Variable Help="Wording that means a notification is an all-clear. Case-insensitive, | separates alternatives." Desc="Resolved when subject contains" Default="returned to normal|is back|back online|finished|completed|resolved|restored|has been fixed">RESOLVE_PATTERN</Variable>
    </Variables>
    <Script>
      <![CDATA[
#!/bin/bash
############
{0}
############

############
# Tasqs notification agent $VERSION — https://github.com/tasqs-public/unraid-agent
#
# Quick test with default values:
#   bash /boot/config/plugins/dynamix/notifications/agents/Tasqs.sh
# Quick test with values set through environment (all vars are optional)
#   EVENT="My Event" SUBJECT="My Subject" DESCRIPTION="My Description" IMPORTANCE="alert" bash /boot/config/plugins/dynamix/notifications/agents/Tasqs.sh
# Full test of notification system
#   /usr/local/emhttp/webGui/scripts/notify -e "My Event" -s "My Subject" -d "My Description" -i "alert"
# Send a sample warning and its all-clear:
#   bash /boot/config/plugins/dynamix/notifications/agents/Tasqs.sh --test
#
# Results are logged with \`logger -t tasqs\`; the webhook URL is never logged.
############

# Map the Agents-tab fields onto the script's settings.
VERSION='$VERSION'
HOOK="\${HOOK_URL:-}"
SECRET="\${SIGNING_SECRET:-}"; [[ "\$SECRET" == none ]] && SECRET=''
LEVELS='normal warning alert'            # the importance grid on the Notifications page is the filter
KEY_MODE="\${KEY_MODE:-stem}"
RESOLVE_PATTERN="\${RESOLVE_PATTERN:-returned to normal|is back|finished|completed|resolved}"
TIMEOUT=10
[[ "\$HOOK" == *PASTE_YOUR_WEBHOOK_URL* ]] && HOOK=''
$body
      ]]>
    </Script>
  </Agent>
EOF

# ── Icon: the Tasqs mark (same as the browser extension's) ──
if [[ ! -f "$OUT/tasqs.png" ]]; then
  echo "plugin/tasqs.png missing — copy a 48x48 PNG there first" >&2; exit 1
fi

md5xml=$(md5sum "$OUT/Tasqs.xml" | cut -d' ' -f1)
md5png=$(md5sum "$OUT/tasqs.png" | cut -d' ' -f1)

cat > "$OUT/tasqs.plg" <<EOF
<?xml version='1.0' standalone='yes'?>
<!DOCTYPE PLUGIN [
<!ENTITY name      "tasqs">
<!ENTITY author    "Tasqs">
<!ENTITY version   "$PLG_VERSION">
<!ENTITY launch    "Settings/Notifications">
<!ENTITY gitURL    "$RAW">
<!ENTITY pluginURL "&gitURL;/plugin/tasqs.plg">
]>

<PLUGIN name="&name;" author="&author;" version="&version;" launch="&launch;" pluginURL="&pluginURL;" icon="&gitURL;/plugin/tasqs.png" support="https://github.com/tasqs-public/unraid-agent" min="6.12.0">

<CHANGES>
##&version;
- Tasqs notification agent $VERSION: adds "Tasqs" to Settings -> Notifications -> Agents.
  Every notification becomes a task in Tasqs; an all-clear completes it.
  Source and changelog: https://github.com/tasqs-public/unraid-agent
</CHANGES>

<!-- The agent template and icon are kept on the flash drive, so they are
     downloaded once and found again at every boot without the network.
     unRAID rebuilds / from the image at boot, so the install script below
     copies them into the webGUI every boot; the enabled agent itself lives on
     the flash drive (/boot/config/plugins/dynamix/notifications/agents/Tasqs.sh)
     and keeps your settings. -->
<FILE Name="/boot/config/plugins/&name;/Tasqs.xml">
<URL>&gitURL;/plugin/Tasqs.xml</URL>
<MD5>$md5xml</MD5>
</FILE>

<FILE Name="/boot/config/plugins/&name;/tasqs.png">
<URL>&gitURL;/plugin/tasqs.png</URL>
<MD5>$md5png</MD5>
</FILE>

<!-- What the Plugins page shows. -->
<FILE Name="/usr/local/emhttp/plugins/&name;/README.md">
<INLINE>
**Tasqs**

Turn unRAID notifications into tasks in Tasqs (tasqs.com). Adds a "Tasqs" agent to Settings -> Notifications -> Agents: paste your webhook URL, tick the levels to forward, done. A disk running hot becomes a task due today; when it returns to normal, the task completes itself. Needs a Tasqs Premium or Power User plan.
</INLINE>
</FILE>

<FILE Run="/bin/bash">
<INLINE>
mkdir -p /usr/local/emhttp/plugins/dynamix/agents /usr/local/emhttp/plugins/dynamix/icons
cp -f /boot/config/plugins/&name;/Tasqs.xml /usr/local/emhttp/plugins/dynamix/agents/Tasqs.xml || { echo "Tasqs: /boot/config/plugins/&name;/Tasqs.xml is missing"; exit 1; }
cp -f /boot/config/plugins/&name;/tasqs.png /usr/local/emhttp/plugins/dynamix/icons/tasqs.png || { echo "Tasqs: /boot/config/plugins/&name;/tasqs.png is missing"; exit 1; }
echo ""
echo "-----------------------------------------------------------"
echo " Tasqs notification agent installed."
echo " Settings -> Notifications -> Agents -> Tasqs: paste your"
echo " webhook URL (Profile -> Webhooks in Tasqs) and enable it."
echo "-----------------------------------------------------------"
echo ""
</INLINE>
</FILE>

<!-- Removal: take the template and icon away. The enabled agent on the flash
     drive is yours (it keeps working as a custom agent); delete it from the
     Notifications page, or by hand, if you no longer want it. -->
<FILE Run="/bin/bash" Method="remove">
<INLINE>
rm -f /usr/local/emhttp/plugins/dynamix/agents/Tasqs.xml
rm -f /usr/local/emhttp/plugins/dynamix/icons/tasqs.png
rm -rf /usr/local/emhttp/plugins/tasqs
rm -f /boot/config/plugins/&name;/Tasqs.xml /boot/config/plugins/&name;/tasqs.png
echo "Tasqs notification agent removed (your enabled agent on /boot was left in place)."
</INLINE>
</FILE>

</PLUGIN>
EOF

echo "plugin/Tasqs.xml ($VERSION, md5 $md5xml)"
echo "plugin/tasqs.plg ($PLG_VERSION)"
