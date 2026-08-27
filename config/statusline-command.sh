#!/bin/bash
# Claude Code statusline: model | cwd (~-relative) | git branch | context remaining | 7d cost
# Reads the Claude Code JSON payload from stdin. Must never error or print
# noise: works with jq missing, fields absent, and outside a git repo.

# ============================================================================
# Daily token-cost estimate (since local midnight) — EDIT THESE to keep current
# [2026-08-07] Switched from rolling 7-day to "today" at the owner's request.
# Variable/function names still say WEEKLY — kept to avoid churn; the window
# is what changed, not the mechanism.
# ============================================================================
# [2026-08-07] Back to REAL per-model API pricing at the owner's request. A single
# blended rate looked simpler but charged cache-READ tokens at the full input rate,
# and 98% of all tokens here are cache reads — that inflated the weekly figure from
# ~55k to ~547k baht. Real pricing discounts cache reads ~10x, which is what the
# providers actually bill, so these numbers mean something.
#
# The money figure is an ESTIMATE, not a bill: token counts multiplied by published API
# per-token rates. On a subscription plan you are not charged this; it is here to show
# what the same work would have cost through the API, which is how you tell whether the
# plan is worth it. Set CC_STATUSLINE_RATE and CC_STATUSLINE_CURRENCY for your currency;
# a rate below the spot rate is the safer default, so the figure never overstates.
CURRENCY_LABEL="${CC_STATUSLINE_CURRENCY:-USD}"
WEEKLY_USD_TO_LOCAL="${CC_STATUSLINE_RATE:-1}"

# USD per 1,000,000 tokens, matched by substring against the model id in the
# transcript. Columns: input / output / cache-write / cache-read.
# Cache-write uses the 1h-TTL rate (2x input) because Claude Code caches at 1h.
# [2026-08-07] Repriced for auto model selection (model changes turn-to-turn, so
# every tier must be right, not just the pinned one): added the Fable tier
# ($10/$50); corrected Opus from legacy Opus<=4.1 pricing ($15/$75) to current
# Opus 4.5+/5 pricing ($5/$25); moved Haiku from 3.5 ($0.80/$4) to 4.5 ($1/$5).
WEEKLY_PRICE_FABLE_IN=10.00;  WEEKLY_PRICE_FABLE_OUT=50.00;   WEEKLY_PRICE_FABLE_CW=20.00; WEEKLY_PRICE_FABLE_CR=1.00
WEEKLY_PRICE_OPUS_IN=5.00;    WEEKLY_PRICE_OPUS_OUT=25.00;    WEEKLY_PRICE_OPUS_CW=10.00;  WEEKLY_PRICE_OPUS_CR=0.50
WEEKLY_PRICE_HAIKU_IN=1.00;   WEEKLY_PRICE_HAIKU_OUT=5.00;    WEEKLY_PRICE_HAIKU_CW=2.00;  WEEKLY_PRICE_HAIKU_CR=0.10
# Sonnet tier, also the fallback for any unmatched model id.
WEEKLY_PRICE_DEFAULT_IN=3.00; WEEKLY_PRICE_DEFAULT_OUT=15.00; WEEKLY_PRICE_DEFAULT_CW=6.00; WEEKLY_PRICE_DEFAULT_CR=0.30

# Scanning every transcript on every render is too slow for a statusline, so
# the computed figure is cached. On a stale cache the OLD value is printed
# immediately and the refresh happens in the background, so a render never
# waits on the scan (measured cold: ~7s — far too long to block on).
WEEKLY_CACHE_FILE="$HOME/.claude/.statusline-weekly-cache"
WEEKLY_CACHE_MAX_AGE_SEC=1800

# Reads $HOME/.claude/projects/*/*.jsonl transcripts, sums token usage from
# assistant turns since local midnight (today), and prints the token+baht segment.
# Prints nothing at all on any failure (no jq, no projects dir, unreadable
# files, zero usage, clock oddities, ...) — the caller just omits the segment.
_weekly_cost_segment() {
  local now mtime cache_age cached fresh=0
  now=$(date +%s 2>/dev/null) || return 0

  if [ -f "$WEEKLY_CACHE_FILE" ]; then
    mtime=$(stat -f %m "$WEEKLY_CACHE_FILE" 2>/dev/null)
    if [ -n "$mtime" ]; then
      cache_age=$(( now - mtime ))
      if [ "$cache_age" -ge 0 ] 2>/dev/null && [ "$cache_age" -lt "$WEEKLY_CACHE_MAX_AGE_SEC" ] 2>/dev/null; then
        fresh=1
      fi
    fi
    cached=$(cat "$WEEKLY_CACHE_FILE" 2>/dev/null)
  fi

  # Fresh cache: print and stop.
  if [ "$fresh" = "1" ] && [ -n "$cached" ]; then
    printf '%s' "$cached"
    return 0
  fi

  # Stale cache but we still have the previous value: show it NOW and refresh
  # in the background. A statusline renders constantly; blocking it on a ~7s
  # transcript scan is worse than showing a figure that is up to an hour old.
  # A lock file keeps overlapping renders from starting several scans at once.
  if [ -n "$cached" ]; then
    printf '%s' "$cached"
    local lock="${WEEKLY_CACHE_FILE}.lock"
    # [fixed 2026-08-11] A refresh killed before its rmdir leaves the lock behind
    # forever, and every later render then fails mkdir and silently skips the
    # refresh — so the statusline shows one frozen figure with nothing to explain
    # it. Seen for real: the lock was orphaned at 04:54 when the machine ran out of
    # memory during a training run, and the cost segment still read 338 baht at
    # 14:54 when the true figure was 4,525. A scan takes ~7s, so any lock older
    # than a couple of minutes belongs to a process that is gone; break it.
    local lock_mtime lock_age
    if [ -d "$lock" ]; then
      lock_mtime=$(stat -f %m "$lock" 2>/dev/null)
      if [ -n "$lock_mtime" ]; then
        lock_age=$(( now - lock_mtime ))
        [ "$lock_age" -gt 120 ] 2>/dev/null && rmdir "$lock" 2>/dev/null
      else
        rmdir "$lock" 2>/dev/null   # unreadable mtime: treat as stale rather than wedge forever
      fi
    fi
    if mkdir "$lock" 2>/dev/null; then
      # The redirect must wrap the WHOLE subshell, not just the compute call.
      # The caller reads this function through $( ), which waits for every
      # process still holding the stdout pipe — leaving even a silent `rmdir`
      # attached to it made the "background" refresh block for ~5s anyway.
      ( _weekly_cost_compute; rmdir "$lock" 2>/dev/null ) >/dev/null 2>&1 </dev/null &
      disown 2>/dev/null
    fi
    return 0
  fi

  # No cache at all (first ever run): compute inline so something is shown.
  _weekly_cost_compute
}

# Does the actual scan and writes the cache. Split out so the stale path above
# can run it detached.
_weekly_cost_compute() {
  command -v jq >/dev/null 2>&1 || return 0
  local proj_dir="$HOME/.claude/projects"
  [ -d "$proj_dir" ] || return 0

  # "Today" = since local midnight, converted to UTC because transcript
  # timestamps are UTC ("...Z") — comparing local time directly would shift
  # the window by 7 hours.
  local cutoff midnight_epoch
  midnight_epoch=$(date -v0H -v0M -v0S +%s 2>/dev/null)
  [ -n "$midnight_epoch" ] || return 0
  cutoff=$(date -u -r "$midnight_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
  [ -n "$cutoff" ] || return 0

  # Each assistant API response can be logged as several JSONL lines (one
  # per content block, e.g. thinking + tool_use) that all repeat the SAME
  # message id and the SAME usage totals — dedupe by message id so tokens
  # aren't counted twice per response.
  local segment
  segment=$(
    find "$proj_dir" -type f -name '*.jsonl' -mtime -2 -exec cat {} + 2>/dev/null \
    | jq -R --arg cutoff "$cutoff" -r '
        (try fromjson catch null) as $o
        | select($o != null and ($o|type)=="object")
        | select($o.type == "assistant")
        | select(($o.timestamp // "") >= $cutoff)
        | ($o.message.id // "") as $id
        | ($o.message.model // "unknown") as $m
        | ($o.message.usage // {}) as $u
        | [$id, $m, ($u.input_tokens//0), ($u.output_tokens//0), ($u.cache_creation_input_tokens//0), ($u.cache_read_input_tokens//0)]
        | @tsv
      ' 2>/dev/null \
    | awk -F'\t' \
        -v usd_thb="$WEEKLY_USD_TO_LOCAL" \
        -v fable_in="$WEEKLY_PRICE_FABLE_IN" -v fable_out="$WEEKLY_PRICE_FABLE_OUT" -v fable_cw="$WEEKLY_PRICE_FABLE_CW" -v fable_cr="$WEEKLY_PRICE_FABLE_CR" \
        -v opus_in="$WEEKLY_PRICE_OPUS_IN" -v opus_out="$WEEKLY_PRICE_OPUS_OUT" -v opus_cw="$WEEKLY_PRICE_OPUS_CW" -v opus_cr="$WEEKLY_PRICE_OPUS_CR" \
        -v haiku_in="$WEEKLY_PRICE_HAIKU_IN" -v haiku_out="$WEEKLY_PRICE_HAIKU_OUT" -v haiku_cw="$WEEKLY_PRICE_HAIKU_CW" -v haiku_cr="$WEEKLY_PRICE_HAIKU_CR" \
        -v def_in="$WEEKLY_PRICE_DEFAULT_IN" -v def_out="$WEEKLY_PRICE_DEFAULT_OUT" -v def_cw="$WEEKLY_PRICE_DEFAULT_CW" -v def_cr="$WEEKLY_PRICE_DEFAULT_CR" '
      {
        id = $1; model = $2; inp = $3 + 0; outp = $4 + 0; cw = $5 + 0; cr = $6 + 0;
        key = (id != "" ? id : ("noid_" NR));
        if (seen[key]++) next;
        total_tokens += inp + outp + cw + cr;
        if (index(model, "fable") > 0 || index(model, "mythos") > 0) { pi = fable_in; po = fable_out; pcw = fable_cw; pcr = fable_cr }
        else if (index(model, "opus") > 0)  { pi = opus_in;  po = opus_out;  pcw = opus_cw;  pcr = opus_cr }
        else if (index(model, "haiku") > 0) { pi = haiku_in; po = haiku_out; pcw = haiku_cw; pcr = haiku_cr }
        else                                { pi = def_in;   po = def_out;   pcw = def_cw;   pcr = def_cr }
        cost_usd += (inp/1000000)*pi + (outp/1000000)*po + (cw/1000000)*pcw + (cr/1000000)*pcr;
      }
      END {
        if (total_tokens > 0) { printf "%.0f %.0f", total_tokens, cost_usd * usd_thb }
      }
    '
  )

  local out="" tok thb tok_h thb_fmt
  if [ -n "$segment" ]; then
    tok=$(printf '%s' "$segment" | awk '{print $1}')
    thb=$(printf '%s' "$segment" | awk '{print $2}')
    if [ -n "$tok" ] && [ -n "$thb" ]; then
      # [fixed 2026-08-07] The old version capped the unit at M, so 2.87 billion
      # printed as "2866.2M" — wrong suffix, and the trailing .2 on a 4-digit
      # number is noise. Now the suffix always steps up (K -> M -> B -> T) so the
      # mantissa stays 1-999, and the decimals scale with it: 2 for a 1-digit
      # mantissa (2.87B keeps the detail an integer "2B" would throw away),
      # 1 for 2 digits, none once it is 3 digits and precision no longer needs it.
      tok_h=$(awk -v n="$tok" 'BEGIN{
        u[1] = ""; u[2] = "K"; u[3] = "M"; u[4] = "B"; u[5] = "T";
        i = 1; while (n >= 1000 && i < 5) { n /= 1000; i++ }
        if (i == 1)       printf "%d%s", n, u[i];
        else if (n < 10)  printf "%.2f%s", n, u[i];
        else if (n < 100) printf "%.1f%s", n, u[i];
        else              printf "%.0f%s", n, u[i];
      }' 2>/dev/null)
      thb_fmt=$(printf '%.0f' "$thb" 2>/dev/null | rev | sed 's/\([0-9]\{3\}\)/\1,/g' | rev | sed 's/^,//')
      [ -n "$tok_h" ] && [ -n "$thb_fmt" ] && out="📉 Token ${tok_h} | 💸 ${thb_fmt} ${CURRENCY_LABEL}"
    fi
  fi

  printf '%s' "$out" > "$WEEKLY_CACHE_FILE" 2>/dev/null
  printf '%s' "$out"
}

# ============================================================================
# Second row: the 5-hour and 7-day quota gauges.
#
# [added 2026-08-27, owner's request] "สร้างบรรทัดเพิ่มมา ใต้นั้น ทำเป็น (5h[▓▓░░░]14% rst:4h 51m)
# สีเขียว และ weekly สีฟ้า" — with a screenshot of the exact shape. Deliberately a SECOND row
# rather than more segments on the first: an earlier attempt to fit these beside the cost figure
# pushed the uncommitted-file count off the end of the pane, where it was silently truncated. Row
# one says what has been spent; row two says what is left.
#
# Free to render, unlike everything on row one. Claude Code hands both windows to the statusline
# on stdin — .rate_limits.five_hour / .seven_day, each carrying used_percentage and a resets_at
# epoch — so there is no transcript scan, no cache, and nothing that can go stale. The row is
# omitted entirely when the field is absent (an older CLI, or an API-key account that has no
# subscription window), rather than printed empty.
# ============================================================================

# How long until a window resets: "51m", "4h 51m", "2d 23h".
#
# [2026-08-27] Capped at TWO units. The weekly window was the only thing on the row printing three
# ("2d 23h 8m") while the 5-hour one printed one ("28m"), and that asymmetry was what read as off
# about it ("ตรง weekly ยังแปลกๆ"). The dropped minute was never information anyway — nobody plans
# around the 8th minute of something three days away.
_rate_limit_until() {
  local secs="$1" d h m
  case "$secs" in ''|*[!0-9-]*) return 0 ;; esac
  [ "$secs" -lt 0 ] 2>/dev/null && secs=0
  d=$(( secs / 86400 )); h=$(( (secs % 86400) / 3600 )); m=$(( (secs % 3600) / 60 ))
  if   [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  else                      printf '%dm' "$m"
  fi
}

# One gauge: "5h[■□□□□]14% rst:4h 51m".
#
# [2026-08-27] The glyphs went ░▓ -> ░█ -> ▁▄ -> □■, each on the owner's eye. What was wrong with
# the full block was height, not weight: it fills the cell top to bottom, so the bar towered over
# every letter beside it ("มันสูงไป"). The squares sit at about text height, which is what
# "เท่ากับ size ตัวอักษร" asked for, and the outline keeps the empty part of the track visible.
#
# One caveat, accepted: U+25A0/25A1 are East Asian AMBIGUOUS width, so a terminal set to render
# ambiguous glyphs double-width draws this row twice as wide. It costs nothing but width — the row
# has no column alignment for a shift to break — but it is the reason to reach for ▄/▁ or █/░ (all
# box-drawing, all unambiguously single-width) if this ever looks stretched somewhere else.
#
# The bar is 6 cells, and two rounding rules keep it honest at the ends: any usage at all lights
# one cell (so 3% cannot read as untouched), and a FULL bar is reserved for a window genuinely at
# the cap (so 95% cannot look identical to 100%).
_rate_limit_gauge() {
  local label="$1" pct="$2" resets="$3" color="$4" now="$5"
  case "$pct" in ''|*[!0-9]*) return 0 ;; esac
  [ "$pct" -gt 100 ] 2>/dev/null && pct=100

  # FIVE cells, so one cell is exactly 20% and the bar can be read as a fraction. It was six, and
  # six does not divide anything a percentage lands on: 72% filled four of six, which reads as 67%
  # and undersells it by a whole cell ("1w[■■■■□□]72% ผิด, ควรเป็น 1w[■■■■□]72%").
  #
  # The old rule reserving a FULL bar for exactly 100% is gone with it. At five cells it collapsed
  # everything from 70% to 99% into the same four-cell picture, which is worse than what it bought:
  # now 90% and above fill the bar, and 90% vs 100% is the one distinction the printed number is
  # already making right beside it. Any usage at all still lights one cell, so 1% cannot read as
  # untouched.
  local n=5 filled i=0 bar=""
  filled=$(( (pct * n + 50) / 100 ))
  [ "$pct" -gt 0 ] && [ "$filled" -lt 1 ] && filled=1
  while [ "$i" -lt "$n" ]; do
    if [ "$i" -lt "$filled" ]; then bar="${bar}■"; else bar="${bar}□"; fi
    i=$(( i + 1 ))
  done

  local off=$'\033[0m' rst=""
  case "$resets" in
    ''|*[!0-9]*) : ;;
    *) rst=$(_rate_limit_until $(( resets - now )) 2>/dev/null) ;;
  esac

  if [ -n "$rst" ]; then
    printf '%s%s[%s]%s%% rst:%s%s' "$color" "$label" "$bar" "$pct" "$rst" "$off"
  else
    printf '%s%s[%s]%s%%%s' "$color" "$label" "$bar" "$pct" "$off"
  fi
}

# Builds the whole second row. The two windows are told apart by colour before either number is
# read; see the palette note below the jq call for why this pair.
_rate_limit_segment() {
  local payload="$1" now
  [ -n "$payload" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  now=$(date +%s 2>/dev/null) || return 0

  # Separated by ';', NOT by a tab. A tab is an IFS *whitespace* character, so bash collapses runs
  # of them and strips leading ones — a payload carrying only the weekly window (both 5h fields
  # empty) then shifted its values two places left and rendered the weekly figure under a "5h"
  # label. Caught in testing, and only ever visible in the one case the gauge exists to be
  # trusted in.
  #
  # used_percentage is floored: a fractional percent would print as "84.6%" and break the integer
  # arithmetic that sizes the bar.
  local raw fh_pct fh_at wk_pct wk_at
  raw=$(printf '%s' "$payload" | jq -r '
      (.rate_limits // empty)
      | [ (.five_hour.used_percentage // "" | if type=="number" then floor else . end),
          (.five_hour.resets_at        // "" | if type=="number" then floor else . end),
          (.seven_day.used_percentage  // "" | if type=="number" then floor else . end),
          (.seven_day.resets_at        // "" | if type=="number" then floor else . end) ]
      | map(tostring) | join(";")' 2>/dev/null) || return 0
  [ -n "$raw" ] || return 0
  IFS=';' read -r fh_pct fh_at wk_pct wk_at <<< "$raw"

  # Pink for the 5-hour window, sky blue for the weekly one. Two rules picked this pair.
  #
  # Warm goes to the window that can actually stop you today; the weekly one is slow news and
  # takes the cool colour. And they must not be confusable at a glance — pink against sky blue
  # separates on a dark background in a way green against cyan did not, which is what the owner
  # was looking at when they asked for this ("ลอง 5h สีชมพูดูหรือแดง").
  #
  # RED was the other candidate for 5h and was deliberately not taken: spending it as a permanent
  # label would leave nothing to say "nearly out" with. It stays free for that meaning.
  #
  # 256-colour rather than the basic 8: the basic magenta and cyan are the same two the terminal
  # theme reassigns, so the pair rendered differently in each theme. To change either, swap the
  # number — 205 is a hotter pink, 203 red, 80 a deeper cyan, 79 teal.
  local pink=$'\033[38;5;212m' sky=$'\033[38;5;117m' out="" one
  one=$(_rate_limit_gauge "5h" "$fh_pct" "$fh_at" "$pink" "$now" 2>/dev/null)
  [ -n "$one" ] && out="$one"
  one=$(_rate_limit_gauge "1w" "$wk_pct" "$wk_at" "$sky" "$now" 2>/dev/null)
  [ -n "$one" ] && { [ -n "$out" ] && out="$out | $one" || out="$one"; }

  # The row says what it is. Row one is a mix of unrelated figures and reads fine unlabelled, but
  # two bracketed bars on a line of their own do not announce that they are the SUBSCRIPTION
  # quota rather than, say, this session's context.
  [ -n "$out" ] && out="⏳ Limit : $out"

  printf '%s' "$out"
}

# Uncommitted-file count for the project directory.
#
# [added 2026-08-25, owner's request] "ใน cli มันไม่รู้" — nothing in the terminal shows that work is
# sitting uncommitted, and this project commits locally many times a day. A number here is the only
# place it is visible without stopping to run git status.
#
# Counts what `git status --porcelain` lists, which is staged + unstaged + untracked. Untracked is
# included on purpose: a new file nobody has added yet is exactly the kind of work that gets lost.
#
# Speed matters more here than anywhere else in this file, since a statusline renders constantly.
# Measured in this repo over 8 runs: 0.06s average, 0.09s worst, with one 1.18s cold-cache outlier on
# the very first call after boot. That is cheap enough to run inline rather than cache it — a cached
# count would be worse than none, since the whole point is knowing the CURRENT state.
#
# Silent on everything: not a repo, git missing, git erroring, a clean tree. The caller then omits
# the segment entirely rather than printing a zero, so a clean tree reads as calm instead of noisy.
_uncommitted_segment() {
  local dir="$1" n
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  (
    cd "$dir" 2>/dev/null || exit 0
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
    n=$(git status --porcelain 2>/dev/null | grep -c '^' 2>/dev/null)
    case "$n" in ''|*[!0-9]*) exit 0 ;; esac
    [ "$n" -gt 0 ] || exit 0
    printf '📝 %s No-Commit' "$n"
  )
}

input=$(cat)

model=""
cwd=""
remaining=""

if command -v jq >/dev/null 2>&1; then
  model=$(printf '%s' "$input" | jq -r '.model.display_name // empty' 2>/dev/null)
  # project_dir first: show the project ROOT, not whatever
  # subdirectory the last tool call happened to cd into (e.g. scratchpad).
  cwd=$(printf '%s' "$input" | jq -r '.workspace.project_dir // .workspace.current_dir // .cwd // empty' 2>/dev/null)
  remaining=$(printf '%s' "$input" | jq -r '.context_window.remaining_percentage // empty' 2>/dev/null)
fi

[ -z "$cwd" ] && cwd="$PWD"

# line. It was the least useful thing on it: the folder is already in the tmux status bar, in the
# window title, and in the shell prompt, so this was the fourth copy of the same word.
#
# The project name was dropped from this line on purpose: the folder is already in the tmux
# status bar, the window title and the shell prompt, so it was the fourth copy of the same word.
line=""
[ -n "$model" ] && line="🚀 $model"

weekly=$(_weekly_cost_segment 2>/dev/null)
if [ -n "$weekly" ]; then
  [ -n "$line" ] && line="$line | $weekly" || line="$weekly"
fi

uncommitted=$(_uncommitted_segment "$cwd" 2>/dev/null)
if [ -n "$uncommitted" ]; then
  [ -n "$line" ] && line="$line | $uncommitted" || line="$uncommitted"
fi

printf '%s\n' "$line"

# Row two. Printed only when the payload actually carries the windows, so an older CLI or an
# API-key account gets the single row it has always had rather than a stray blank line.
limits=$(_rate_limit_segment "$input" 2>/dev/null)
if [ -n "$limits" ]; then
  printf '%s\n' "$limits"
fi

# Explicit, because the last command above is a test: without this, every render on an account
# that has no subscription window exits 1 and reports the statusline as failing.
exit 0
