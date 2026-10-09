#!/bin/bash
# github-watch.sh: controlla le interazioni (commenti, review, stato) sui
# contributi upstream dello spike e registra i DELTA in github-interactions.log.
# State watermark: workdir/github-watch.state. Idempotente e silenzioso se
# nessuna novita'.

set -u
WORKDIR="/Users/pantinor/data/repo/personal/vulkan-opencl"
STATE="$WORKDIR/github-watch.state"
LOG="$WORKDIR/github-interactions.log"
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$WORKDIR"
touch "$STATE"

log_new() { # repo, kind, number, author, ts, body-snippet
    local repo="$1" kind="$2" num="$3" author="$4" ts="$5" body="$6"
    {
        echo "[$NOW_UTC] $repo#$num $kind by $author @ $ts"
        echo "  $body" | fold -s -w 100 | head -8
        echo
    } >> "$LOG"
}

# --- issue/PR comments via REST issues API (covers both for issues; for PRs
# issue comments are the conversation thread) ---
watch_issue_comments() {
    local repo="$1" num="$2" kind="comment"
    local latest
    latest=$(gh api "repos/$repo/issues/$num/comments?per_page=100&sort=created&direction=desc" \
        --jq '.[0] | "\(.id) \(.created_at) \(.user.login) \(.body[0:120])"' 2>/dev/null) || return 0
    [ -z "$latest" ] && return 0
    local id ts author body
    read -r id ts author body <<< "$latest"
    # jq emits a bare "null" when the thread has no comments yet
    [ "$id" = "null" ] && return 0
    local key="comment:$repo#$num"
    local prev
    prev=$(grep "^$key " "$STATE" 2>/dev/null | awk '{print $2}')
    if [ "$prev" != "$id" ]; then
        log_new "$repo" "$kind" "$num" "$author" "$ts" "$body"
    fi
    echo "$key $id" >> "$STATE.tmp"
}

# --- reviews via pulls reviews API ---
watch_pr_reviews() {
    local repo="$1" num="$2" kind="review"
    local latest
    latest=$(gh api "repos/$repo/pulls/$num/reviews?per_page=100" \
        --jq '[.[] | select(.body != "")][0] | "\(.id) \(.submitted_at) \(.user.login) \(.body[0:120])"' 2>/dev/null) || return 0
    [ -z "$latest" ] && latest="none null null null"
    local id ts author body
    read -r id ts author body <<< "$latest"
    [ "$id" = "none" ] && return 0
    [ "$id" = "null" ] && return 0
    local key="review:$repo#$num"
    local prev
    prev=$(grep "^$key " "$STATE" 2>/dev/null | awk '{print $2}')
    if [ "$prev" != "$id" ]; then
        log_new "$repo" "$kind" "$num" "$author" "$ts" "$body"
    fi
    echo "$key $id" >> "$STATE.tmp"
}

# --- inline review comments via pulls comments API (the channel the
# issue-comments and reviews probes above cannot see) ---
watch_inline_comments() {
    local repo="$1" num="$2" kind="inline"
    local latest
    latest=$(gh api "repos/$repo/pulls/$num/comments?per_page=10&sort=created&direction=desc" \
        --jq '.[0] | "\(.id) \(.created_at) \(.user.login) \(.path):\(.line // .original_line) \(.body[0:120])"' 2>/dev/null) || return 0
    [ -z "$latest" ] && return 0
    local id ts author body
    read -r id ts author body <<< "$latest"
    [ "$id" = "null" ] && return 0
    local key="inline:$repo#$num"
    local prev
    prev=$(grep "^$key " "$STATE" 2>/dev/null | awk '{print $2}')
    if [ "$prev" != "$id" ]; then
        log_new "$repo" "$kind" "$num" "$author" "$ts" "$body"
    fi
    echo "$key $id" >> "$STATE.tmp"
}

# --- PR merge/state check ---
watch_pr_state() {
    local repo="$1" num="$2"
    gh pr view "$num" --repo "$repo" --json state,mergedAt \
        --jq '"\(.state) \(.mergedAt // "-")"' 2>/dev/null > "$WORKDIR/.gh-ps.$$"
    local st merged
    read -r st merged < "$WORKDIR/.gh-ps.$$"
    local key="state:$repo#$num"
    local prev
    prev=$(grep "^$key " "$STATE" 2>/dev/null | awk '{print $2, $3}')
    if [ "$prev" != "$st $merged" ]; then
        log_new "$repo" "state" "$num" "-" "-" "state=$st merged=$merged"
        echo "$key $st $merged" >> "$STATE.tmp"
    else
        echo "$key $st $merged" >> "$STATE.tmp"
    fi
    rm -f "$WORKDIR/.gh-ps.$$"
}

CLSPV="google/clspv"
CLVK="kpet/clvk"

# PR: comments, reviews, inline comments, state
for n in 1660 1661 1662 1663; do
    watch_issue_comments "$CLSPV" "$n"
    watch_pr_reviews "$CLSPV" "$n"
    watch_inline_comments "$CLSPV" "$n"
    watch_pr_state "$CLSPV" "$n"
done
# clvk PRs + issues
for n in 907 908; do
    watch_issue_comments "$CLVK" "$n"
    watch_pr_reviews "$CLVK" "$n"
    watch_inline_comments "$CLVK" "$n"
    watch_pr_state "$CLVK" "$n"
done
watch_issue_comments "$CLVK" 906
watch_issue_comments "$CLVK" 600
# libkrun
watch_issue_comments "libkrun/libkrun" 910
# hashcat
watch_issue_comments "hashcat/hashcat" 4959
# podman (retratto, ma traccio risposte)
watch_issue_comments "podman-container-tools/podman" 29918

# Swap-in the new watermark atomically. Keys touched this run come from
# STATE.tmp and win; keys whose probe early-returned (API error, empty
# thread) keep their previous line so they are not re-reported as deltas.
if [ -f "$STATE.tmp" ]; then
    cat "$STATE.tmp" "$STATE" | awk '!seen[$1]++' | sort > "$STATE.merged.$$"
    mv "$STATE.merged.$$" "$STATE"
    rm -f "$STATE.tmp"
fi
exit 0
