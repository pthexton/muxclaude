#!/usr/bin/env node
/**
 * Example Claude Code PreToolUse hook.
 *
 * What this is for
 * ----------------
 * PreToolUse hooks are the *deterministic* veto: when one returns
 * `permissionDecision: "ask"`, Claude Code blocks the tool call and asks
 * the user to approve before proceeding. Unlike instructions in CLAUDE.md
 * or a system prompt, this is enforced by the harness — Claude cannot
 * choose to ignore it, even if it forgot, was confused, or weighed the
 * trade-off differently than you would.
 *
 * Use this pattern any time you have a class of action that is hard to
 * undo, depends on context the model can't see, or has off-screen side
 * effects you specifically want a human to confirm.
 *
 * What this specific example catches
 * ----------------------------------
 * `gh pr create` invocations whose title or body mention more than one
 * unique Jira-style ticket key (e.g. PROJ-1, PROJ-2). The trap it closes:
 * many GitHub→Jira automations auto-transition every ticket key they see
 * in a merged PR body to Done. If Claude lists "follow-up: PROJ-456" in
 * the body of a PR that only actually addresses PROJ-455, PROJ-456 also
 * gets closed on merge — silently, sometimes days later.
 *
 * Customising it for your tracker
 * -------------------------------
 * Edit TICKET_PREFIX below to your project key, and (optionally) the
 * reason text. To gate on something completely different, swap the
 * "is this a gh pr create?" check and the "what's wrong with it?" logic.
 * Everything else (stdin handling, output shape, fail-open posture) is
 * generic to the PreToolUse contract.
 *
 * Wiring it up
 * ------------
 * Copy this file somewhere stable (e.g. ~/.claude/hooks/) and add it to
 * ~/.claude/settings.json:
 *
 *     {
 *       "hooks": {
 *         "PreToolUse": [
 *           {
 *             "matcher": "Bash",
 *             "hooks": [
 *               {
 *                 "type": "command",
 *                 "command": "/absolute/path/to/this-script.js",
 *                 "timeout": 5
 *               }
 *             ]
 *           }
 *         ]
 *       }
 *     }
 *
 * The script self-filters on `gh pr create`, so the `Bash` matcher is just
 * an efficiency hint — it isn't called for non-Bash tool calls.
 *
 * Why JavaScript: Claude Code itself runs on Node.js, so `node` is already
 * on PATH wherever this hook will run.
 */

"use strict";

// ─── EDIT ME ────────────────────────────────────────────────────────────────
// Your Jira (or other tracker) project key prefix. The hook scans the
// command for `<PREFIX>-<digits>` and triggers when more than one unique
// match is found.
const TICKET_PREFIX = "PROJ";
// ────────────────────────────────────────────────────────────────────────────

const fs = require("fs");

// Fail open on any unexpected error: the worst-case outcome of this hook
// breaking is losing the safety net, not blocking Claude from working.
function bailQuietly() { process.exit(0); }
process.on("uncaughtException", bailQuietly);

let input;
try {
  input = JSON.parse(fs.readFileSync(0, "utf8"));
} catch {
  bailQuietly();
}

// Only inspect Bash tool calls; everything else passes through.
if (input.tool_name !== "Bash") bailQuietly();

const command = (input.tool_input && input.tool_input.command) || "";

// Only inspect `gh pr create` invocations; other gh subcommands and other
// commands pass through unchanged.
if (!/\bgh\s+pr\s+create\b/.test(command)) bailQuietly();

const ticketRe = new RegExp(`\\b${TICKET_PREFIX}-\\d+\\b`, "g");
const keys = [...new Set(command.match(ticketRe) || [])].sort();

// One ticket (or none) is fine — that's the normal case.
if (keys.length <= 1) bailQuietly();

const reason = [
  `PR command mentions ${keys.length} ${TICKET_PREFIX} keys: ${keys.join(", ")}.`,
  "",
  `If your GitHub→Jira automation auto-transitions every ${TICKET_PREFIX}-NNN`,
  "key it sees in a merged PR body to Done, the extra keys here may get",
  "closed accidentally on merge.",
  "",
  "Options:",
  "  - Drop the extra keys from the PR body, or",
  `  - Phrase them so the smart-commit parser won't match (fenced code block,`,
  `    or write the key with a U+2011 non-breaking hyphen, e.g. "${TICKET_PREFIX}‑NNN"),`,
  "    or",
  "  - Accept the auto-transitions and revert them after merge.",
  "",
  "Approve to proceed with the command as written.",
].join("\n");

const output = {
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: reason,
  },
};

process.stdout.write(JSON.stringify(output) + "\n");
process.exit(0);
