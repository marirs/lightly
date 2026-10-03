#!/usr/bin/env python3
"""PreToolUse hook: refuse heavy commands that bypass scripts/heavy.

Instructions to agents alone did not keep heavy jobs serial (three ran at once
on 2026-10-03, load 60 on 10 cores), so this enforces it.

A Bash command is split into simple commands on ; && || | and newlines. A
simple command is heavy when the program it runs (after any VAR=value
assignments and transparent prefixes such as time/nohup/env) is a build tool,
an emulator, or a simulator boot/install/launch/io. Arguments are not
inspected, so `grep xcodebuild log.txt` is allowed. A `bash -c '...'` body is
checked recursively. A simple command that starts with scripts/heavy is
allowed whatever it runs, because the wrapper holds the lock.

The iOS Simulator MCP build tool is refused outright because it cannot take
the lock.
"""
import json
import os
import re
import shlex
import sys

HEAVY_PROGRAMS = {"xcodebuild", "gradlew", "gradle", "emulator", "swift"}
SWIFT_HEAVY_SUBCOMMANDS = {"build", "test"}
SIMCTL_HEAVY_SUBCOMMANDS = {"boot", "install", "launch", "io"}
TRANSPARENT_PREFIXES = {"time", "nohup", "env", "exec", "caffeinate", "command", "sudo"}
SHELLS = {"bash", "sh", "zsh"}
COMMAND_OPERATORS = {";", "&&", "||", "|", "&", ";;", "|&"}
ENV_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
COMMAND_SUBSTITUTION_OPENER = re.compile(r"\$\(|`")
REFUSAL = (
    "Heavy jobs must run one at a time through the shared lock. "
    "Re-run as: scripts/heavy <label> <command> (from the repo root; use the "
    "absolute path /Users/sg/Documents/Dev/Projects/lightly/scripts/heavy elsewhere). "
    "Put a whole simulator/emulator session (boot, captures, shutdown) inside one "
    "invocation, e.g. scripts/heavy android-captures bash -c '...'. "
    "Queue and run times are logged in /tmp/lightly-heavy.log."
)


def strip_subshell_opener(word: str) -> str:
    return word.lstrip("$").lstrip("(").lstrip("`")


def split_simple_commands(command: str) -> list[list[str]]:
    """Quote-aware split into simple commands (word lists).

    Quoted text, such as a bash -c body, stays one word, so a ; inside it does
    not end the outer command.
    """
    lexer = shlex.shlex(command.replace("\n", " ; "), posix=True, punctuation_chars=";&|")
    lexer.whitespace_split = True
    simple_commands: list[list[str]] = [[]]
    try:
        for token in lexer:
            if token in COMMAND_OPERATORS:
                simple_commands.append([])
            else:
                simple_commands[-1].append(token)
    except ValueError:
        # Unbalanced quotes: judge on plain whitespace words instead.
        return [command.split()]
    return [words for words in simple_commands if words]


def program_words(words: list[str]) -> list[str]:
    """Drop leading env assignments, transparent prefixes and subshell parens."""
    index = 0
    while index < len(words):
        word = strip_subshell_opener(words[index])
        if ENV_ASSIGNMENT.match(word) or os.path.basename(word) in TRANSPARENT_PREFIXES or word == "":
            index += 1
            continue
        break
    return [strip_subshell_opener(w) for w in words[index:]]


def substitution_bypasses_lock(raw_words: list[str]) -> bool:
    """Check $(...) and `...` bodies found anywhere in the arguments."""
    for word in raw_words:
        for opener in COMMAND_SUBSTITUTION_OPENER.finditer(word):
            body = word[opener.end():].rstrip(")`")
            if body and command_bypasses_lock(body):
                return True
    return False


def simple_command_bypasses_lock(raw_words: list[str]) -> bool:
    words = program_words(raw_words)
    if not words:
        return False
    program_path = words[0]
    program = os.path.basename(program_path)
    if program_path.endswith("scripts/heavy"):
        return False
    if substitution_bypasses_lock(raw_words):
        return True
    if program in SHELLS and "-c" in words[1:]:
        body_index = words.index("-c") + 1
        return body_index < len(words) and command_bypasses_lock(words[body_index])
    if program == "xcrun" and len(words) > 1:
        words = words[1:]
        program = os.path.basename(words[0])
    if program == "simctl":
        return len(words) > 1 and words[1] in SIMCTL_HEAVY_SUBCOMMANDS
    if program == "swift":
        return len(words) > 1 and words[1] in SWIFT_HEAVY_SUBCOMMANDS
    if program == "open":
        return "Simulator" in words and "-a" in words
    if program.startswith("qemu-system"):
        return True
    return program in HEAVY_PROGRAMS


def command_bypasses_lock(command: str) -> bool:
    return any(simple_command_bypasses_lock(words) for words in split_simple_commands(command))


def main() -> None:
    event = json.load(sys.stdin)
    tool_name = event.get("tool_name", "")
    if tool_name.endswith("iOS_Simulator__build"):
        print(REFUSAL, file=sys.stderr)
        sys.exit(2)
    if tool_name != "Bash":
        sys.exit(0)
    if command_bypasses_lock(event.get("tool_input", {}).get("command", "")):
        print(REFUSAL, file=sys.stderr)
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
