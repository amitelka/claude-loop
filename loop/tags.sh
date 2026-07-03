#!/usr/bin/env bash
# loop/tags.sh — canonical log-tag substrings, the SINGLE source of truth for the writer↔consumer
# coupling. stats/doctor grep these via the vars below (never string literals). tests/contract_tags_test.sh
# asserts every TAG_* is still emitted by a writer, so a refactor that renames a tag fails CI instead of
# silently reading 0 — the failure that made `last review` show 9 days stale (writers dropped `review: done`
# while loopctl still greped it). Change a tag HERE and the consumer moves with it.
TAG_REVIEW_START="review: start"        # a review ran (stats: reviews-started + last-review)
TAG_REVIEW_OK="valid proposal"          # review produced a materialized proposal (stats: reviews-ok)
TAG_HARVEST="harvest: nightly"          # nightly harvest pass (stats: triggers-harvest)
TAG_GARDEN_START="garden: start"        # a gardener run began (stats: triggers-garden)
TAG_STOP_TRIGGER="stop: trigger"        # Stop-hook review trigger (stats: triggers-stop)
TAG_SESSION_END="session-end: review"   # SessionEnd review trigger (stats: triggers-session-end)
TAG_SELFHEAL="self-heal"                # presence hook spawned a self-heal worker (stats: presence-spawns)
TAG_GARDEN_CATCHUP="garden catch-up"    # a garden catch-up fired (stats: self-heal garden-catchup)
TAG_MINER_CATCHUP="miner catch-up"      # a miner catch-up fired (stats: self-heal miner-catchup)
TAG_MINE_DONE="mine-skills: done"       # a mine run completed (stats: miner runs real/dry)
TAG_MINE_FAILED="mine-skills: FAILED"   # a mine run hard-failed (stats: miner fails)
TAG_REGRET="  regret "                  # gardener pruned a slug the reviewer later re-captured (stats: regret)
TAG_INDEX_REBUILD="index rebuild"       # derived retriever index rebuilt on write (materialize/garden → build_index.py)
