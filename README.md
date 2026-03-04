# synofoto-media-count

A read-only bash script that queries the Synology Photos PostgreSQL database (`synofoto`) to give you a clear breakdown of what's actually in your photo library.

## The Problem

If you back up iPhone photos to Synology Photos, you have three numbers that don't agree:

1. **Your phone** says you have N photos.
2. **The file system** (Finder, File Station, `ls`) shows roughly 2N files because each Live Photo is stored as a separate HEIC image and MOV video.
3. **Synology Photos** doesn't give you a total count at all.

Synology Photos *has* database infrastructure to group Live Photo pairs (via `live_additional.grouping_key`), but this grouping is reportedly inconsistent with some users claiming it has worked at times and others saying they've never seen it. I am aware of no reliable way to get a count from the app, and no way to tell from the file system which files are Live Photo pairs, which are standalone photos, and which are standalone videos.

This script queries the database directly and gives you a clear breakdown: plain photos, Live Photo groups (and their component files), standalone videos, incomplete groups (e.g., a video without its paired still), and anything else. You can reconcile this against your phone to verify your backup is complete.

## Requirements

- Synology DSM 7.x with Synology Photos installed
- SSH access to the NAS
- `sudo` privileges (or direct `postgres` user access)
- Python 3 (included in DSM 7.x) — only needed for `publish-to-ha.py`

## Safety

This script is **read-only**. It runs `SELECT` queries only and never modifies your data.

## Usage

```bash
# Copy the script to your NAS and make it executable
chmod +x count-media.sh

# Basic run — auto-selects '/MobileBackup' if it exists and runs against the current user by default
sudo ./count-media.sh

# Interactive mode — choose a folder from a list
sudo ./count-media.sh --interactive

# Scope to a specific user
sudo ./count-media.sh --user-name bexelbie --interactive

# Show raw/technical details
sudo ./count-media.sh --verbose

# Inspect specific categories of files
sudo ./count-media.sh --inspect incomplete-live-groups --all
sudo ./count-media.sh --inspect standalone-other --sample 30
sudo ./count-media.sh --inspect type:0 --all

# List available inspect categories
sudo ./count-media.sh --list-categories
```

## Example Output

```
Target: /MobileBackup (recursive)

Readable Interpretation
  Non-live photos: 1240
  Live photos (collapsed items): 3500
  Standalone videos: 402
  Standalone other items: 12
  Incomplete live groups: 3 (units: 6)
```

With `--verbose`, additional sections show raw unit counts, type breakdowns, and live-group vs. standalone splits.

## All Options

```
--folder-id ID           Count media for a specific folder ID
--folder-path PATH       Count media for an exact folder path/name
--user-name NAME         Restrict to a specific username
--user-id ID             Restrict to a specific user ID
--all-users              Search across all users
--list-users             List users and exit
--filter TEXT            Filter for folder listing (default: MobileBackup)
--list-folders           List matching folders and exit
--interactive            Prompt to choose a folder
--exact-folder           Count only the selected folder, not subfolders
--verbose                Show technical sections (raw counts and type tables)
--list-categories        List inspect categories and exit
--inspect TARGET         Show rows for a category (e.g. incomplete-live-groups)
--sample N               Sample size for --inspect (default: 20)
--all                    Show all rows for --inspect
--photo-type N           Override photo type value (default: 0)
--video-type N           Override video type value (default: 1)
--db-name NAME           Database name (default: synofoto)
--json                   Machine-readable JSON output (see below)
--no-sudo                Use psql directly instead of sudo -u postgres
```

## JSON Output

Use `--json` for machine-readable output, useful for automation and integration:

```bash
# JSON array of all users
sudo ./count-media.sh --list-users --json --all-users
# [{"name":"alice","id":1},{"name":"bob","id":2}]

# JSON media counts for a specific user
sudo ./count-media.sh --user-name alice --json
# {"user":"alice","photos":1240,"live_photos":3500,"videos":402,"other":12,"total":5154}
```

## Home Assistant Integration

`publish-to-ha.py` pushes media counts for all Synology Photos users to Home Assistant via MQTT auto-discovery. Sensors appear automatically — no HA configuration needed.

### Setup

1. In Home Assistant, create a [long-lived access token](https://www.home-assistant.io/docs/authentication/#your-account-profile) (Profile → Security → Long-Lived Access Tokens).

2. Copy both scripts to your NAS and edit the top of `publish-to-ha.py`:
   ```python
   HA_URL = "https://your-ha-instance:8123"
   HA_TOKEN = "your-token-here"
   ```

3. Test it:
   ```bash
   sudo ./publish-to-ha.py
   ```

4. Set up a scheduled task in Synology DSM:
   - **Control Panel → Task Scheduler → Create → Scheduled Task → User-defined script**
   - **User:** root
   - **Schedule:** every 6 hours (or your preference)
   - **Command:** `/path/to/publish-to-ha.py`

   Since the task runs as root, `sudo -u postgres` inside the script works without a password.

### What it creates in HA

For each Synology Photos user, five sensors appear automatically:

| Entity | Description |
|--------|-------------|
| `sensor.synology_photos_<user>_non_live_photos` | Non-live photos |
| `sensor.synology_photos_<user>_live_photos` | Live photos (collapsed) |
| `sensor.synology_photos_<user>_videos` | Standalone videos |
| `sensor.synology_photos_<user>_other` | Other items |
| `sensor.synology_photos_<user>_total_media` | Total media items |

These are standard HA sensors — use them in dashboards, automations, or long-term statistics for graphing trends.

If a Synology Photos user is removed, their sensors are automatically marked unavailable (history is preserved for past time ranges).

### Example Dashboard Cards

These cards require two HACS frontend integrations:
- **[auto-entities](https://github.com/thomasloven/lovelace-auto-entities)** — auto-populates cards based on entity patterns
- **[apexcharts-card](https://github.com/RomRider/apexcharts-card)** — advanced charts including stacked bars

**Current totals per user** (auto-updates when users are added/removed):

```yaml
type: custom:auto-entities
card:
  type: entities
  title: Synology Photos — Totals
filter:
  include:
    - entity_id: sensor.synology_photos_*_total_media
  exclude:
    - state: unavailable
sort:
  method: name
```

**Stacked bar chart — media breakdown per user over time:**

```yaml
type: custom:auto-entities
card:
  type: custom:apexcharts-card
  header:
    show: true
    title: Synology Photos — Media Breakdown
  graph_span: 90d
  span:
    end: day
  apex_config:
    chart:
      stacked: true
    legend:
      show: true
  yaxis:
    - id: count
      min: 0
  # series is populated by auto-entities
filter:
  include:
    - entity_id: sensor.synology_photos_*_non_live_photos
      options:
        name: Photos
        type: column
        color: "#4CAF50"
        group_by:
          func: last
          duration: 1d
    - entity_id: sensor.synology_photos_*_live_photos
      options:
        name: Live Photos
        type: column
        color: "#2196F3"
        group_by:
          func: last
          duration: 1d
    - entity_id: sensor.synology_photos_*_videos
      options:
        name: Videos
        type: column
        color: "#FF9800"
        group_by:
          func: last
          duration: 1d
    - entity_id: sensor.synology_photos_*_other
      options:
        name: Other
        type: column
        color: "#9E9E9E"
        group_by:
          func: last
          duration: 1d
  exclude:
    - state: unavailable
card_param: series
```

**Simple total trend line per user:**

```yaml
type: custom:auto-entities
card:
  type: custom:apexcharts-card
  header:
    show: true
    title: Synology Photos — Total Over Time
  graph_span: 90d
  span:
    end: day
filter:
  include:
    - entity_id: sensor.synology_photos_*_total_media
      options:
        type: line
        group_by:
          func: last
          duration: 1d
  exclude:
    - state: unavailable
card_param: series
```

## Notes

- Defaults to `sudo -u postgres psql -d synofoto`. Use `--no-sudo` if already running as `postgres` or if your user has direct DB access.
- When run via `sudo`, the script automatically detects the invoking user from `SUDO_USER`, so it scopes to your library without needing `--user-name`. Use `--all-users` or `--user-name` to override.
- Counts include nested subfolders by default. Use `--exact-folder` for a single folder.
- Inspect categories are case-insensitive and accept spaces or underscores.
- For iPhone MobileBackup libraries, the defaults (`photo_type=0`, `video_type=1`) should be correct. Override with `--photo-type` and `--video-type` if your installation differs.

## License

MIT
