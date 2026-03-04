#!/usr/bin/env bash
# ABOUTME: Counts Synology Photos media units for a selected folder in the synofoto database.
# ABOUTME: Supports repeated use with raw type breakdown and live-collapsed totals.

set -euo pipefail

DB_NAME="synofoto"
PHOTO_TYPE=0
VIDEO_TYPE=1
FOLDER_FILTER="MobileBackup"
FOLDER_ID=""
FOLDER_PATH=""
USER_ID=""
USER_NAME=""
ALL_USERS=0
LIST_USERS=0
LIST_ONLY=0
INTERACTIVE=0
NO_SUDO=0
INCLUDE_SUBFOLDERS=1
VERBOSE=0
LIST_CATEGORIES=0
INSPECT_TARGET=""
INSPECT_SAMPLE=20
INSPECT_ALL=0
JSON_OUTPUT=0

usage() {
  cat <<'EOF'
Usage:
  count-media.sh [options]

Options:
  --folder-id ID           Count media for a specific folder ID.
  --folder-path PATH       Count media for an exact folder path/name.
  --user-name NAME         Restrict folder search/resolve to a specific username.
  --user-id ID             Restrict folder search/resolve to a specific user ID.
  --all-users              Disable user scoping and search across all users.
  --list-users             List user_info IDs and names, then exit.
  --filter TEXT            Filter used when listing candidate folders (default: MobileBackup).
  --list-folders           Only list matching folders and exit.
  --interactive            Prompt to choose a folder from filtered list.
                           When not interactive, script auto-selects '/<filter>' if it exists.
  --exact-folder           Count only the selected folder, not nested subfolders.
  --verbose                Show technical sections (raw counts and type tables).
  --list-categories        List inspect categories and exit.
  --inspect TARGET         Show sample/all rows for a category (e.g. type:0).
  --sample N               Sample size for --inspect (default: 20).
  --all                    Show all rows for --inspect target.
  --photo-type N           Internal unit.type value for photos (default: 0).
  --video-type N           Internal unit.type value for videos (default: 1).
  --db-name NAME           Database name (default: synofoto).
  --json                   Output machine-readable JSON instead of human text.
                           With --list-users: JSON array of {name, id}.
                           Otherwise: JSON object with media counts.
  --no-sudo                Use psql directly instead of sudo -u postgres.
  -h, --help               Show help.

Notes:
  When run via sudo, the invoking user is detected automatically via
  SUDO_USER, so --user-name is not needed for your own library.

Examples:
  ./count-media.sh --list-users
  ./count-media.sh --list-folders
  ./count-media.sh --list-folders --all-users
  ./count-media.sh --interactive
  ./count-media.sh --interactive --user-name bexelbie
  ./count-media.sh --interactive --user-id 2
  ./count-media.sh --list-categories
  ./count-media.sh --inspect standalone-other --sample 30
  ./count-media.sh --inspect type:0 --all
  ./count-media.sh --folder-path '/MobileBackup'
  ./count-media.sh --folder-id 1234
EOF
}

build_psql_cmd() {
  if [[ "$NO_SUDO" -eq 1 || "$(id -un)" == "postgres" ]]; then
    PSQL_CMD=(psql -d "$DB_NAME" -X -q -v ON_ERROR_STOP=1 -t -A -F $'\t' -P pager=off)
  else
    PSQL_CMD=(sudo -u postgres psql -d "$DB_NAME" -X -q -v ON_ERROR_STOP=1 -t -A -F $'\t' -P pager=off)
  fi
}

run_query() {
  local sql="$1"
  shift || true
  printf '%s\n' "$sql" | "${PSQL_CMD[@]}" "$@"
}

clean_psql_output() {
  sed '/^$/d' | sed -E '/^\([0-9]+ rows?\)$/d'
}

require_db() {
  if ! command -v psql >/dev/null 2>&1; then
    echo "ERROR: psql is not installed or not in PATH." >&2
    exit 1
  fi
}

list_users() {
  local sql
  sql=$(cat <<'SQL'
select name, id
from user_info
order by name
SQL
)
  if [[ "$JSON_OUTPUT" -eq 1 ]]; then
    local rows
    rows=$(run_query "$sql" | clean_psql_output)
    local first=1
    printf '['
    while IFS=$'\t' read -r uname uid; do
      [[ -z "${uname:-}" ]] && continue
      [[ -z "${uid:-}" ]] && continue
      [[ "$first" -eq 1 ]] && first=0 || printf ','
      printf '{"name":"%s","id":%s}' "$uname" "$uid"
    done <<< "$rows"
    printf ']\n'
    return
  fi
  run_query "$sql"
}

resolve_user_id_by_name() {
  local username="$1"
  local sql
  sql=$(cat <<'SQL'
select id
from user_info
where name = :'username'
order by id
SQL
)

  local rows
  rows=$(run_query "$sql" -v username="$username" | clean_psql_output | awk '/^[0-9]+$/')
  if [[ -z "$rows" ]]; then
    echo "ERROR: No Synology Photos user matches username '$username'." >&2
    echo "Use --list-users to see available usernames." >&2
    exit 1
  fi

  local count
  count=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
  if [[ "$count" -gt 1 ]]; then
    echo "ERROR: Multiple user_info IDs matched username '$username'. Use --user-id explicitly." >&2
    printf '%s\n' "$rows" >&2
    exit 1
  fi

  USER_ID=$(printf '%s\n' "$rows" | head -n1)
}

resolve_user_scope() {
  if [[ "$ALL_USERS" -eq 1 || -n "$USER_ID" ]]; then
    return
  fi

  if [[ -n "$USER_NAME" ]]; then
    resolve_user_id_by_name "$USER_NAME"
    return
  fi

  local username
  username="${SUDO_USER:-$(id -un)}"
  resolve_user_id_by_name "$username"
}

resolve_folder_by_path() {
  local path="$1"
  local sql
  if [[ -n "$USER_ID" ]]; then
    sql=$(cat <<'SQL'
select id, id_user, name
from folder
where name = :'folder_path'
  and id_user = :'user_id'::int
order by id
SQL
)
  else
    sql=$(cat <<'SQL'
select id, id_user, name
from folder
where name = :'folder_path'
order by id
SQL
)
  fi

  local rows
  if [[ -n "$USER_ID" ]]; then
    rows=$(run_query "$sql" -v folder_path="$path" -v user_id="$USER_ID" | clean_psql_output | awk -F'\t' 'NF>=3 && $1 ~ /^[0-9]+$/')
  else
    rows=$(run_query "$sql" -v folder_path="$path" | clean_psql_output | awk -F'\t' 'NF>=3 && $1 ~ /^[0-9]+$/')
  fi
  if [[ -z "$rows" ]]; then
    echo "ERROR: No folder found with exact path/name: $path" >&2
    exit 1
  fi

  local count
  count=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
  if [[ "$count" -gt 1 ]]; then
    echo "ERROR: Multiple folders matched path '$path'. Use --folder-id instead:" >&2
    printf '%s\n' "$rows" >&2
    exit 1
  fi

  FOLDER_ID=$(printf '%s\n' "$rows" | cut -f1)
}

list_folders() {
  local filter="$1"
  local sql
  if [[ -n "$USER_ID" ]]; then
    sql=$(cat <<'SQL'
select id, id_user, name
from folder
where name ilike '%' || :'folder_filter' || '%'
  and id_user = :'user_id'::int
order by id_user, name
SQL
)
    run_query "$sql" -v folder_filter="$filter" -v user_id="$USER_ID"
  else
    sql=$(cat <<'SQL'
select id, id_user, name
from folder
where name ilike '%' || :'folder_filter' || '%'
order by id_user, name
SQL
)
    run_query "$sql" -v folder_filter="$filter"
  fi
}

choose_folder_interactive() {
  local filter="$1"
  local rows
  rows=$(list_folders "$filter" | clean_psql_output | awk -F'\t' 'NF>=3 && $1 ~ /^[0-9]+$/')

  if [[ -z "$rows" ]]; then
    echo "ERROR: No folders matched filter: $filter" >&2
    exit 1
  fi

  echo "Matching folders (index | folder_id | user_id | name):"
  local i=1
  while IFS=$'\t' read -r folder_id user_id folder_name; do
    [[ -z "${folder_id:-}" ]] && continue
    printf '%3d | %s | %s | %s\n' "$i" "$folder_id" "$user_id" "$folder_name"
    i=$((i + 1))
  done <<< "$rows"

  local max_index=$((i - 1))
  local pick=""
  while true; do
    read -r -p "Select index (1-${max_index}): " pick
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= max_index )); then
      break
    fi
    echo "Invalid selection."
  done

  FOLDER_ID=$(printf '%s\n' "$rows" | sed -n "${pick}p" | cut -f1)
}

try_resolve_folder_by_path() {
  local path="$1"
  local sql
  if [[ -n "$USER_ID" ]]; then
    sql=$(cat <<'SQL'
select id, id_user, name
from folder
where name = :'folder_path'
  and id_user = :'user_id'::int
order by id
SQL
)
  else
    sql=$(cat <<'SQL'
select id, id_user, name
from folder
where name = :'folder_path'
order by id
SQL
)
  fi

  local rows
  if [[ -n "$USER_ID" ]]; then
    rows=$(run_query "$sql" -v folder_path="$path" -v user_id="$USER_ID" | clean_psql_output | awk -F'\t' 'NF>=3 && $1 ~ /^[0-9]+$/')
  else
    rows=$(run_query "$sql" -v folder_path="$path" | clean_psql_output | awk -F'\t' 'NF>=3 && $1 ~ /^[0-9]+$/')
  fi

  local count
  count=$(printf '%s\n' "$rows" | sed '/^$/d' | wc -l | tr -d ' ')
  if [[ "$count" -ne 1 ]]; then
    return 1
  fi

  FOLDER_ID=$(printf '%s\n' "$rows" | cut -f1)
  return 0
}

type_label() {
  local type_value="$1"
  if [[ "$type_value" == "$PHOTO_TYPE" ]]; then
    printf 'photo'
  elif [[ "$type_value" == "$VIDEO_TYPE" ]]; then
    printf 'video'
  else
    printf 'other'
  fi
}

print_inspect_categories() {
  cat <<'EOF'
inspect categories:
  non-live-photos
  live-photo-items
  incomplete-live-groups
  live-still-files
  live-companion-files
  incomplete-live-units
  standalone-videos
  standalone-other
  type:<n>                (example: type:0)
EOF
}

print_inspection() {
  local folder_id="$1"
  local target="$2"
  local normalized_target
  normalized_target=$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]' | sed -E 's/[ _]+/-/g')

  local folder_filter_clause
  if [[ "$INCLUDE_SUBFOLDERS" -eq 1 ]]; then
    folder_filter_clause="(f.name = s.name or f.name like s.name || '/%')"
  else
    folder_filter_clause="f.id = :'folder_id'::int"
  fi

  local limit_clause=""
  if [[ "$INSPECT_ALL" -eq 0 ]]; then
    limit_clause="limit :'sample'::int"
  fi

  local type_value=""
  local mode="$normalized_target"
  if [[ "$normalized_target" =~ ^type:([0-9]+)$ ]]; then
    type_value="${BASH_REMATCH[1]}"
    mode="type"
  fi

  local file_filter=""
  local group_filter=""
  case "$mode" in
    non-live-photos)
      file_filter="not g.is_live_group and s.type = :'photo_type'::int"
      ;;
    live-still-files)
      file_filter="g.is_live_group and s.type = :'photo_type'::int"
      ;;
    live-companion-files)
      file_filter="g.is_live_group and s.type <> :'photo_type'::int"
      ;;
    incomplete-live-groups)
      group_filter="g.has_live_key and not g.is_live_group"
      ;;
    incomplete-live-units)
      file_filter="g.has_live_key and not g.is_live_group"
      ;;
    standalone-videos)
      file_filter="not g.is_live_group and s.type = :'video_type'::int"
      ;;
    standalone-other)
      file_filter="not g.is_live_group and s.type <> :'photo_type'::int and s.type <> :'video_type'::int"
      ;;
    live-photo-items)
      group_filter="g.is_live_group"
      ;;
    type)
      file_filter="s.type = :'inspect_type'::int"
      ;;
    *)
      echo "ERROR: Unknown inspect target '$target'." >&2
      echo "Use --list-categories to see allowed values." >&2
      exit 1
      ;;
  esac

  if [[ "$mode" == "live-photo-items" || "$mode" == "incomplete-live-groups" ]]; then
    local group_sql
    group_sql=$(cat <<SQL
with selected as (
  select id_user, name
  from folder
  where id = :'folder_id'::int
),
scoped as (
  select
    u.id as unit_id,
    u.type,
    u.filename,
    f.name as folder_path,
    la.grouping_key,
    (la.grouping_key is not null) as has_live_key,
    coalesce(la.grouping_key, 'unit:' || u.id::text) as group_key
  from selected s
  join folder f on f.id_user = s.id_user
  join unit u on u.id_folder = f.id
  left join live_additional la on la.id_unit = u.id
  where ${folder_filter_clause}
),
group_rollup as (
  select
    group_key,
    bool_or(has_live_key) as has_live_key,
    count(*) as unit_count,
    sum((type = :'photo_type'::int)::int) as photo_count,
    sum((type = :'video_type'::int)::int) as video_count,
    sum((type <> :'photo_type'::int and type <> :'video_type'::int)::int) as other_count
  from scoped
  group by group_key
),
group_flags as (
  select
    group_key,
    unit_count,
    photo_count,
    video_count,
    other_count,
    has_live_key,
    (photo_count > 0 and (video_count + other_count) > 0 and unit_count > 1) as is_live_group
  from group_rollup
)
select
  g.group_key,
  g.photo_count,
  g.video_count,
  g.other_count,
  min(case when s.type = :'photo_type'::int then s.folder_path || '/' || s.filename end) as still_example,
  min(case when s.type <> :'photo_type'::int then s.folder_path || '/' || s.filename end) as companion_example
from group_flags g
join scoped s on s.group_key = g.group_key
where ${group_filter}
group by g.group_key, g.photo_count, g.video_count, g.other_count
order by still_example nulls last, g.group_key
${limit_clause}
SQL
)

    local rows
    if [[ "$INSPECT_ALL" -eq 1 ]]; then
      rows=$(run_query "$group_sql" -v folder_id="$folder_id" -v photo_type="$PHOTO_TYPE" -v video_type="$VIDEO_TYPE" | clean_psql_output)
    else
      rows=$(run_query "$group_sql" -v folder_id="$folder_id" -v photo_type="$PHOTO_TYPE" -v video_type="$VIDEO_TYPE" -v sample="$INSPECT_SAMPLE" | clean_psql_output)
    fi

    echo
    echo "Inspect: ${target}"
    printf '  %-28s %-8s %-8s %-8s %s\n' "GroupKey" "Photos" "Videos" "Others" "Examples"
    if [[ -z "$rows" ]]; then
      echo "  (no matches)"
      return
    fi
    while IFS=$'\t' read -r group_key photo_count video_count other_count still_example companion_example; do
      [[ -z "${group_key:-}" ]] && continue
      printf '  %-28s %-8s %-8s %-8s %s | %s\n' \
        "$group_key" \
        "${photo_count:-0}" \
        "${video_count:-0}" \
        "${other_count:-0}" \
        "${still_example:-n/a}" \
        "${companion_example:-n/a}"
    done <<< "$rows"
    return
  fi

  local file_sql
  file_sql=$(cat <<SQL
with selected as (
  select id_user, name
  from folder
  where id = :'folder_id'::int
),
scoped as (
  select
    u.id as unit_id,
    u.type,
    u.filename,
    f.name as folder_path,
    la.grouping_key,
    (la.grouping_key is not null) as has_live_key,
    coalesce(la.grouping_key, 'unit:' || u.id::text) as group_key
  from selected s
  join folder f on f.id_user = s.id_user
  join unit u on u.id_folder = f.id
  left join live_additional la on la.id_unit = u.id
  where ${folder_filter_clause}
),
group_rollup as (
  select
    group_key,
    bool_or(has_live_key) as has_live_key,
    count(*) as unit_count,
    sum((type = :'photo_type'::int)::int) as photo_count,
    sum((type = :'video_type'::int)::int) as video_count,
    sum((type <> :'photo_type'::int and type <> :'video_type'::int)::int) as other_count
  from scoped
  group by group_key
),
group_flags as (
  select
    group_key,
    has_live_key,
    (photo_count > 0 and (video_count + other_count) > 0 and unit_count > 1) as is_live_group
  from group_rollup
)
select
  s.unit_id,
  s.type,
  s.folder_path,
  s.filename,
  coalesce(s.grouping_key, '') as grouping_key,
  coalesce(case when g.is_live_group then 'live-group' else 'standalone' end, 'standalone') as grouping_mode
from scoped s
join group_flags g on g.group_key = s.group_key
where ${file_filter}
order by s.folder_path, s.filename, s.unit_id
${limit_clause}
SQL
)

  local rows
  if [[ "$INSPECT_ALL" -eq 1 ]]; then
    rows=$(run_query "$file_sql" \
      -v folder_id="$folder_id" \
      -v photo_type="$PHOTO_TYPE" \
      -v video_type="$VIDEO_TYPE" \
      -v inspect_type="${type_value:-0}" | clean_psql_output)
  else
    rows=$(run_query "$file_sql" \
      -v folder_id="$folder_id" \
      -v photo_type="$PHOTO_TYPE" \
      -v video_type="$VIDEO_TYPE" \
      -v inspect_type="${type_value:-0}" \
      -v sample="$INSPECT_SAMPLE" | clean_psql_output)
  fi

  echo
  echo "Inspect: ${target}"
  echo "  GroupingMode = derived from grouped unit composition."
  echo "  LiveKey = raw live_additional.grouping_key value (blank means no live key)."
  printf '  %-8s %-6s %-13s %-26s %s\n' "UnitID" "Type" "GroupingMode" "LiveKey" "Path"
  if [[ -z "$rows" ]]; then
    echo "  (no matches)"
    return
  fi
  while IFS=$'\t' read -r unit_id type_num folder_path filename grouping_key grouping_mode; do
    [[ -z "${unit_id:-}" ]] && continue
    printf '  %-8s %-6s %-13s %-26s %s/%s\n' \
      "$unit_id" \
      "$type_num" \
      "${grouping_mode:-standalone}" \
      "${grouping_key:--}" \
      "$folder_path" \
      "$filename"
  done <<< "$rows"
}

print_counts() {
  local folder_id="$1"

  local folder_filter_clause
  if [[ "$INCLUDE_SUBFOLDERS" -eq 1 ]]; then
    folder_filter_clause="(f.name = s.name or f.name like s.name || '/%')"
  else
    folder_filter_clause="f.id = :'folder_id'::int"
  fi

  local folder_sql
  folder_sql=$(cat <<'SQL'
select id, id_user, name
from folder
where id = :'folder_id'::int
SQL
)

  local summary_sql
  summary_sql=$(cat <<SQL
with selected as (
  select id_user, name
  from folder
  where id = :'folder_id'::int
),
scoped as (
  select u.id, u.type, la.grouping_key
  from selected s
  join folder f on f.id_user = s.id_user
  join unit u on u.id_folder = f.id
  left join live_additional la on la.id_unit = u.id
  where ${folder_filter_clause}
)
select
  count(*) as raw_units,
  coalesce(sum((type = :'photo_type'::int)::int), 0) as photos_raw,
  coalesce(sum((type = :'video_type'::int)::int), 0) as videos_raw,
  coalesce(sum((type <> :'photo_type'::int and type <> :'video_type'::int)::int), 0) as other_types_raw,
  count(distinct coalesce(grouping_key, 'unit:' || id::text)) as live_collapsed_units
from scoped
SQL
)

  local breakdown_sql
  breakdown_sql=$(cat <<SQL
with selected as (
  select id_user, name
  from folder
  where id = :'folder_id'::int
)
select u.type, count(*) as cnt
from selected s
join folder f on f.id_user = s.id_user
join unit u on u.id_folder = f.id
where ${folder_filter_clause}
group by u.type
order by u.type
SQL
)

  local interpretation_sql
  interpretation_sql=$(cat <<SQL
with selected as (
  select id_user, name
  from folder
  where id = :'folder_id'::int
),
scoped as (
  select
    u.id,
    u.type,
    la.grouping_key,
    (la.grouping_key is not null) as has_live_key,
    coalesce(la.grouping_key, 'unit:' || u.id::text) as group_key
  from selected s
  join folder f on f.id_user = s.id_user
  join unit u on u.id_folder = f.id
  left join live_additional la on la.id_unit = u.id
  where ${folder_filter_clause}
),
group_rollup as (
  select
    group_key,
    bool_or(has_live_key) as has_live_key,
    count(*) as unit_count,
    sum((type = :'photo_type'::int)::int) as photo_count,
    sum((type = :'video_type'::int)::int) as video_count,
    sum((type <> :'photo_type'::int and type <> :'video_type'::int)::int) as other_count
  from scoped
  group by group_key
),
group_flags as (
  select
    group_key,
    unit_count,
    photo_count,
    video_count,
    other_count,
    has_live_key,
    (photo_count > 0 and (video_count + other_count) > 0 and unit_count > 1) as is_live_group
  from group_rollup
),
scoped_with_flags as (
  select s.type, g.is_live_group
  from scoped s
  join group_flags g on g.group_key = s.group_key
)
select
  coalesce(sum((not is_live_group and photo_count > 0 and (video_count + other_count) = 0)::int), 0) as non_live_photo_items,
  coalesce(sum((is_live_group)::int), 0) as live_photo_items,
  coalesce(sum((case when is_live_group then photo_count else 0 end)), 0) as live_still_files,
  coalesce(sum((case when is_live_group then (video_count + other_count) else 0 end)), 0) as live_companion_files,
  coalesce(sum((not is_live_group and video_count > 0 and photo_count = 0 and other_count = 0)::int), 0) as standalone_video_items,
  coalesce(sum((not is_live_group and other_count > 0 and photo_count = 0 and video_count = 0)::int), 0) as standalone_other_items,
  coalesce(sum((not is_live_group and ((photo_count > 0 and video_count > 0) or (photo_count > 0 and other_count > 0) or (video_count > 0 and other_count > 0)))::int), 0) as mixed_non_live_groups,
  coalesce(sum((has_live_key and not is_live_group)::int), 0) as incomplete_live_groups,
  coalesce(sum((case when has_live_key and not is_live_group then unit_count else 0 end)), 0) as incomplete_live_units
from group_flags
SQL
)

  local type_split_sql
  type_split_sql=$(cat <<SQL
with selected as (
  select id_user, name
  from folder
  where id = :'folder_id'::int
),
scoped as (
  select u.id, u.type, coalesce(la.grouping_key, 'unit:' || u.id::text) as group_key
  from selected s
  join folder f on f.id_user = s.id_user
  join unit u on u.id_folder = f.id
  left join live_additional la on la.id_unit = u.id
  where ${folder_filter_clause}
),
group_rollup as (
  select
    group_key,
    count(*) as unit_count,
    sum((type = :'photo_type'::int)::int) as photo_count,
    sum((type = :'video_type'::int)::int) as video_count,
    sum((type <> :'photo_type'::int and type <> :'video_type'::int)::int) as other_count
  from scoped
  group by group_key
),
group_flags as (
  select
    group_key,
    (photo_count > 0 and (video_count + other_count) > 0 and unit_count > 1) as is_live_group
  from group_rollup
)
select
  s.type,
  count(*) as total_count,
  sum((g.is_live_group)::int) as in_live_groups,
  sum((not g.is_live_group)::int) as outside_live_groups
from scoped s
join group_flags g on g.group_key = s.group_key
group by s.type
order by s.type
SQL
)

  local standalone_other_type_sql
  standalone_other_type_sql=$(cat <<SQL
with selected as (
  select id_user, name
  from folder
  where id = :'folder_id'::int
),
scoped as (
  select u.id, u.type, coalesce(la.grouping_key, 'unit:' || u.id::text) as group_key
  from selected s
  join folder f on f.id_user = s.id_user
  join unit u on u.id_folder = f.id
  left join live_additional la on la.id_unit = u.id
  where ${folder_filter_clause}
),
group_rollup as (
  select
    group_key,
    count(*) as unit_count,
    sum((type = :'photo_type'::int)::int) as photo_count,
    sum((type = :'video_type'::int)::int) as video_count,
    sum((type <> :'photo_type'::int and type <> :'video_type'::int)::int) as other_count
  from scoped
  group by group_key
),
group_flags as (
  select
    group_key,
    (photo_count > 0 and (video_count + other_count) > 0 and unit_count > 1) as is_live_group,
    photo_count,
    video_count,
    other_count
  from group_rollup
)
select s.type, count(*) as cnt
from scoped s
join group_flags g on g.group_key = s.group_key
where not g.is_live_group and g.photo_count = 0 and g.video_count = 0 and g.other_count > 0
group by s.type
order by cnt desc, s.type
SQL
)

  local folder_row
  folder_row=$(run_query "$folder_sql" -v folder_id="$folder_id" | clean_psql_output | head -n1)
  local folder_row_id folder_row_user_id folder_row_name
  IFS=$'\t' read -r folder_row_id folder_row_user_id folder_row_name <<< "$folder_row"

  if [[ "$JSON_OUTPUT" -eq 0 ]]; then
    echo
    if [[ "$INCLUDE_SUBFOLDERS" -eq 1 ]]; then
      echo "Target: ${folder_row_name} (recursive)"
    else
      echo "Target: ${folder_row_name} (exact folder only)"
    fi
  fi

  local summary_row
  summary_row=$(run_query "$summary_sql" \
    -v folder_id="$folder_id" \
    -v photo_type="$PHOTO_TYPE" \
    -v video_type="$VIDEO_TYPE" | clean_psql_output | head -n1)

  local raw_units photos_raw videos_raw other_types_raw live_collapsed_units
  IFS=$'\t' read -r raw_units photos_raw videos_raw other_types_raw live_collapsed_units <<< "$summary_row"

  local interpretation_row
  interpretation_row=$(run_query "$interpretation_sql" \
    -v folder_id="$folder_id" \
    -v photo_type="$PHOTO_TYPE" \
    -v video_type="$VIDEO_TYPE" | clean_psql_output | head -n1)

  local non_live_photo_items live_photo_items live_still_files live_companion_files standalone_video_items standalone_other_items mixed_non_live_groups incomplete_live_groups incomplete_live_units
  IFS=$'\t' read -r \
    non_live_photo_items \
    live_photo_items \
    live_still_files \
    live_companion_files \
    standalone_video_items \
    standalone_other_items \
    mixed_non_live_groups \
    incomplete_live_groups \
    incomplete_live_units <<< "$interpretation_row"

  if [[ "$JSON_OUTPUT" -eq 1 ]]; then
    local photos=${non_live_photo_items:-0}
    local live=${live_photo_items:-0}
    local videos=${standalone_video_items:-0}
    local other=${standalone_other_items:-0}
    local total=$(( photos + live + videos + other ))
    local json_user="${USER_NAME:-${SUDO_USER:-$(id -un)}}"
    # Synology DSM forbids " and \ in usernames, so no JSON escaping needed
    printf '{"user":"%s","photos":%d,"live_photos":%d,"videos":%d,"other":%d,"total":%d}\n' \
      "$json_user" "$photos" "$live" "$videos" "$other" "$total"
    return
  fi

  echo
  echo "Readable Interpretation"
  echo "  Non-live photos: ${non_live_photo_items:-0}"
  echo "  Live photos (collapsed items): ${live_photo_items:-0}"
  echo "  Standalone videos: ${standalone_video_items:-0}"
  echo "  Standalone other items: ${standalone_other_items:-0}"
  echo "  Incomplete live groups: ${incomplete_live_groups:-0} (units: ${incomplete_live_units:-0})"

  local standalone_other_type_rows
  standalone_other_type_rows=$(run_query "$standalone_other_type_sql" \
    -v folder_id="$folder_id" \
    -v photo_type="$PHOTO_TYPE" \
    -v video_type="$VIDEO_TYPE" | clean_psql_output)
  if [[ -n "$standalone_other_type_rows" ]]; then
    echo "  Standalone other types (internal type -> count):"
    while IFS=$'\t' read -r type_value count_value; do
      [[ -z "${type_value:-}" ]] && continue
      echo "    type ${type_value}: ${count_value:-0}"
    done <<< "$standalone_other_type_rows"
  fi

  if [[ "${mixed_non_live_groups:-0}" -gt 0 ]]; then
    echo "  Ambiguous mixed groups: ${mixed_non_live_groups:-0}"
  fi

  if [[ "$VERBOSE" -eq 1 ]]; then
    echo
    echo "Verbose: Folder Context"
    echo "  Folder ID: ${folder_row_id}"
    echo "  User ID: ${folder_row_user_id}"

    echo
    echo "Verbose: Summary Counts"
    echo "  Total Units (raw rows): ${raw_units:-0}"
    echo "  Photos (type=${PHOTO_TYPE}): ${photos_raw:-0}"
    echo "  Videos (type=${VIDEO_TYPE}): ${videos_raw:-0}"
    echo "  Other Types: ${other_types_raw:-0}"
    echo "  Live-Collapsed Units: ${live_collapsed_units:-0}"
    echo "  Live still files: ${live_still_files:-0}"
    echo "  Live companion files: ${live_companion_files:-0}"
    echo "  Incomplete live groups: ${incomplete_live_groups:-0}"
    echo "  Incomplete live units: ${incomplete_live_units:-0}"

    echo
    if [[ "$INCLUDE_SUBFOLDERS" -eq 1 ]]; then
      echo "Verbose: Type Breakdown (raw, recursive scope)"
    else
      echo "Verbose: Type Breakdown (raw, exact folder)"
    fi

    local breakdown_rows
    breakdown_rows=$(run_query "$breakdown_sql" -v folder_id="$folder_id" | clean_psql_output)
    if [[ -z "$breakdown_rows" ]]; then
      echo "  (no units found)"
      return
    fi

    printf '  %-8s %-10s %s\n' "Type" "Category" "Count"
    while IFS=$'\t' read -r type_value count_value; do
      [[ -z "${type_value:-}" ]] && continue
      printf '  %-8s %-10s %s\n' "$type_value" "$(type_label "$type_value")" "${count_value:-0}"
    done <<< "$breakdown_rows"

    local type_split_rows
    type_split_rows=$(run_query "$type_split_sql" \
      -v folder_id="$folder_id" \
      -v photo_type="$PHOTO_TYPE" \
      -v video_type="$VIDEO_TYPE" | clean_psql_output)

    echo
    echo "Verbose: Type Split (live-group vs standalone)"
    if [[ -z "$type_split_rows" ]]; then
      echo "  (no units found)"
      return
    fi
    printf '  %-8s %-10s %-12s %-13s %s\n' "Type" "Category" "Total" "InLiveGroup" "Standalone"
    while IFS=$'\t' read -r type_value total_count in_live_groups outside_live_groups; do
      [[ -z "${type_value:-}" ]] && continue
      printf '  %-8s %-10s %-12s %-13s %s\n' \
        "$type_value" \
        "$(type_label "$type_value")" \
        "${total_count:-0}" \
        "${in_live_groups:-0}" \
        "${outside_live_groups:-0}"
    done <<< "$type_split_rows"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --folder-id)
        FOLDER_ID="$2"
        shift 2
        ;;
      --folder-path)
        FOLDER_PATH="$2"
        shift 2
        ;;
      --filter)
        FOLDER_FILTER="$2"
        shift 2
        ;;
      --user-id)
        USER_ID="$2"
        shift 2
        ;;
      --user-name)
        USER_NAME="$2"
        shift 2
        ;;
      --all-users)
        ALL_USERS=1
        shift
        ;;
      --list-users)
        LIST_USERS=1
        shift
        ;;
      --list-folders)
        LIST_ONLY=1
        shift
        ;;
      --interactive)
        INTERACTIVE=1
        shift
        ;;
      --exact-folder)
        INCLUDE_SUBFOLDERS=0
        shift
        ;;
      --verbose)
        VERBOSE=1
        shift
        ;;
      --list-categories)
        LIST_CATEGORIES=1
        shift
        ;;
      --inspect)
        INSPECT_TARGET="$2"
        shift 2
        ;;
      --sample)
        INSPECT_SAMPLE="$2"
        shift 2
        ;;
      --all)
        INSPECT_ALL=1
        shift
        ;;
      --photo-type)
        PHOTO_TYPE="$2"
        shift 2
        ;;
      --video-type)
        VIDEO_TYPE="$2"
        shift 2
        ;;
      --db-name)
        DB_NAME="$2"
        shift 2
        ;;
      --json)
        JSON_OUTPUT=1
        shift
        ;;
      --no-sudo)
        NO_SUDO=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "ERROR: Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  if [[ "$LIST_CATEGORIES" -eq 1 ]]; then
    print_inspect_categories
    exit 0
  fi

  if [[ ! "$INSPECT_SAMPLE" =~ ^[0-9]+$ ]] || [[ "$INSPECT_SAMPLE" -lt 1 ]]; then
    echo "ERROR: --sample must be a positive integer." >&2
    exit 1
  fi

  if [[ "$ALL_USERS" -eq 1 && ( -n "$USER_ID" || -n "$USER_NAME" ) ]]; then
    echo "ERROR: Use either --all-users or a user scope option (--user-name/--user-id), not both." >&2
    exit 1
  fi

  if [[ -n "$USER_ID" && -n "$USER_NAME" ]]; then
    echo "ERROR: Use either --user-name or --user-id, not both." >&2
    exit 1
  fi

  if [[ "$JSON_OUTPUT" -eq 1 && "$INTERACTIVE" -eq 1 ]]; then
    echo "ERROR: --json and --interactive cannot be used together." >&2
    exit 1
  fi

  require_db
  build_psql_cmd

  if [[ "$LIST_USERS" -eq 1 ]]; then
    list_users
    exit 0
  fi

  resolve_user_scope

  if [[ "$LIST_ONLY" -eq 1 ]]; then
    list_folders "$FOLDER_FILTER"
    exit 0
  fi

  if [[ "$NO_SUDO" -eq 1 && "$JSON_OUTPUT" -eq 0 ]]; then
    echo "Note: --no-sudo requires a valid PostgreSQL role/auth for the current user."
  fi

  if [[ -n "$FOLDER_PATH" && -n "$FOLDER_ID" ]]; then
    echo "ERROR: Use either --folder-id or --folder-path, not both." >&2
    exit 1
  fi

  if [[ -n "$FOLDER_PATH" ]]; then
    resolve_folder_by_path "$FOLDER_PATH"
  elif [[ -z "$FOLDER_ID" && "$INTERACTIVE" -eq 1 ]]; then
    choose_folder_interactive "$FOLDER_FILTER"
  elif [[ -z "$FOLDER_ID" ]]; then
    local default_path="$FOLDER_FILTER"
    if [[ "$default_path" != /* ]]; then
      default_path="/$default_path"
    fi

    if try_resolve_folder_by_path "$default_path"; then
      [[ "$JSON_OUTPUT" -eq 0 ]] && echo "No folder selected. Auto-selected default folder path '$default_path'."
    else
      [[ "$JSON_OUTPUT" -eq 0 ]] && echo "No folder selected. Using interactive selector with filter '$FOLDER_FILTER'."
      choose_folder_interactive "$FOLDER_FILTER"
    fi
  fi

  if [[ -n "$INSPECT_TARGET" ]]; then
    print_inspection "$FOLDER_ID" "$INSPECT_TARGET"
    exit 0
  fi

  print_counts "$FOLDER_ID"
}

main "$@"
