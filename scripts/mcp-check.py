#!/usr/bin/env python3
"""Checks `stowmail mcp` against a real archive (Phase 3 QA), printing only
counts, IDs, sizes and PASS or FAIL: never a subject, sender or body, so the
output can be shared.

Run with the same environment as stowmail itself (STOW_KEYCHAIN=file for
unsigned builds). One account must be enabled for MCP and another disabled:

    STOW_KEYCHAIN=file scripts/mcp-check.py --stowmail <path> --enabled <account> --disabled <account>

<account> is anything `stowmail mcp status` shows for it: ID, address or name.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}{'  (' + detail + ')' if detail else ''}")


class Server:
    def __init__(self, command):
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.next_id = 1

    def request(self, method, params=None):
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            message["params"] = params
        self.next_id += 1
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise SystemExit("The server closed its output (see ~/Library/Logs/Stow/stowmail.log).")
            reply = json.loads(line)
            if reply.get("id") == message["id"]:
                return reply

    def notify(self, method):
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method}) + "\n")
        self.process.stdin.flush()

    def call(self, tool, arguments=None):
        start = time.time()
        reply = self.request("tools/call", {"name": tool, "arguments": arguments or {}})
        took = (time.time() - start) * 1000
        result = reply["result"]
        return result["content"][0]["text"], bool(result.get("isError")), took

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)


def cli(stowmail, *arguments):
    return subprocess.run([stowmail, *arguments], capture_output=True, text=True, check=True).stdout


def leading_number(text):
    match = re.match(r"(\d+) email", text)
    return int(match.group(1)) if match else None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--stowmail", required=True)
    parser.add_argument("--enabled", required=True)
    parser.add_argument("--disabled", help="An account left off, to check it stays invisible. Needs a second account.")
    options = parser.parse_args()
    stowmail = options.stowmail

    # Which accounts are which, from `stowmail mcp status`: "on   <id>  <address>  "<name>"".
    accounts = {}
    for line in cli(stowmail, "mcp", "status").splitlines():
        match = re.match(r'(on |off)\s+(\S+)\s+(\S+)\s+"(.*)"$', line)
        if match:
            accounts[match.group(2)] = (match.group(1).strip() == "on", match.group(3), match.group(4))

    def find(wanted):
        for account_id, (on, address, name) in accounts.items():
            if wanted.lower() in (account_id.lower(), address.lower(), name.lower()) or account_id.startswith(wanted):
                return account_id
        raise SystemExit(f"No account matches {wanted!r} in `stowmail mcp status`.")

    enabled = find(options.enabled)
    disabled = find(options.disabled) if options.disabled else None
    check("the enabled account is on", accounts[enabled][0])
    if disabled:
        check("the disabled account is off", not accounts[disabled][0])
    enabled_address = accounts[enabled][1]
    disabled_address = accounts[disabled][1] if disabled else "\0"

    server = Server([stowmail, "mcp"])
    init = server.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                         "clientInfo": {"name": "mcp-check", "version": "1"}})
    server.notify("notifications/initialized")
    check("initialize", init.get("result", {}).get("serverInfo", {}).get("name") == "stow")
    tools = server.request("tools/list")["result"]["tools"]
    check("four read-only tools", [t["name"] for t in tools] == ["list_folders", "search_messages", "get_thread", "get_attachment"]
          and all(t.get("annotations", {}).get("readOnlyHint") for t in tools))

    timings = {}
    sizes = {}
    subjects = set()

    def call(label, tool, arguments=None):
        text, error, took = server.call(tool, arguments)
        timings.setdefault(tool, []).append(took)
        sizes[label] = len(text)
        for line in text.splitlines():
            if line.startswith("Subject: ") and len(line) > 20:
                subjects.add(line[len("Subject: "):])
        return text, error

    # list_folders: the enabled account only.
    text, error = call("list_folders", "list_folders")
    folder_lines = sum(1 for line in text.splitlines() if line.startswith("  folder: ") or line.startswith("  label: "))
    check("list_folders shows the enabled account only",
          not error and enabled_address in text and disabled_address not in text, f"{folder_lines} folders and labels")

    # search_messages against `stowmail search` for the same account.
    def compare(label, arguments, cli_query):
        text, error = call(label, "search_messages", arguments)
        mcp_total = 0 if text.startswith("No emails") else leading_number(text)
        cli_total = leading_number(cli(stowmail, "search", "--limit", "1", cli_query))
        check(f"search {label}: same total as the CLI", not error and mcp_total == cli_total, f"{mcp_total} and {cli_total}")
        return text

    browse = compare("everything", {}, f"account:{enabled}")
    compare("in inbox", {"folder": "inbox"}, f"in:inbox account:{enabled}")
    compare("in sent", {"folder": "sent"}, f"in:sent account:{enabled}")
    compare("'invoice'", {"query": "invoice"}, f"invoice account:{enabled}")
    compare("'invoice' with attachments", {"query": "invoice", "has_attachment": True}, f"invoice has:attachment account:{enabled}")
    compare("during 2024", {"after": "2024-01-01", "before": "2025-01-01"}, f"after:2024-01-01 before:2025-01-01 account:{enabled}")

    text, error = call("limit 500", "search_messages", {"limit": 500})
    shown = sum(1 for line in text.splitlines() if line.startswith("["))
    check("search caps at 50", shown <= 50, f"{shown} shown")

    for name, value in ([("address", disabled_address), ("ID", disabled)] if disabled else []):
        text, error = call(f"disabled account by {name}", "search_messages", {"account": value})
        check(f"the disabled account cannot be named ({name})", error and "No account available" in text)

    # get_thread on the newest messages, against `stowmail thread`.
    ids = [int(m) for m in re.findall(r"^\[(\d+)\]", browse, re.M)][:10]
    largest = (0, None)
    agreed = 0
    for message in ids:
        text, error = call(f"thread {message}", "get_thread", {"message_id": message})
        mcp_total = int(re.match(r"Conversation of (\d+) email", text).group(1)) if not error else None
        cli_total = leading_number(cli(stowmail, "thread", str(message)))
        agreed += mcp_total == cli_total
        if mcp_total and mcp_total > largest[0]:
            largest = (mcp_total, message)
    check("get_thread: same conversation size as the CLI", bool(ids) and agreed == len(ids), f"{agreed} of {len(ids)}")
    if largest[1]:
        text, _ = call("largest thread", "get_thread", {"message_id": largest[1], "bodies": 20})
        check("largest of those threads stays within the cap", len(text) < 100_000,
              f"{largest[0]} emails, {len(text)} characters with up to 20 bodies")

    # The disabled account's mail answers like mail that does not exist.
    hidden = None
    if disabled:
        lines = cli(stowmail, "search", "--limit", "1", f"account:{disabled}").splitlines()
        hidden = re.match(r"(\d+) ", lines[1]) if len(lines) > 1 else None
    if hidden:
        hidden_id = int(hidden.group(1))
        text, error = call("hidden thread", "get_thread", {"message_id": hidden_id})
        check("get_thread hides the disabled account", error and "No message with ID" in text)
        text, error = call("hidden attachment", "get_attachment", {"message_id": hidden_id, "attachment": 1})
        check("get_attachment hides the disabled account", error and "No message with ID" in text)

    # get_attachment: the first attachment with text among recent mail with attachments.
    text, _ = call("with attachments", "search_messages", {"has_attachment": True, "limit": 20})
    found = False
    for message in [int(m) for m in re.findall(r"^\[(\d+)\]", text, re.M)]:
        thread, _ = call(f"attachments of {message}", "get_thread", {"message_id": message, "bodies": 1})
        block = thread.split(f"===== [{message}]", 1)[-1]
        numbers = re.findall(r"^  (\d+)\. .*, (\d+) characters of text\)$", block, re.M)
        if numbers:
            index, length = int(numbers[0][0]), int(numbers[0][1])
            text, error = call("attachment", "get_attachment", {"message_id": message, "attachment": index, "max_chars": 1_000_000})
            body = text.split("----- attachment text", 1)[-1].split("----- end of attachment text", 1)[0]
            check("get_attachment returns text, capped at 50,000 characters",
                  not error and "The file itself is not available" in text and len(body) <= 50_100,
                  f"{length} characters extracted, {len(body)} returned")
            found = True
            break
    if not found:
        print("SKIP  get_attachment: no attachment with text among the 20 newest emails with attachments")

    server.close()

    # The audit log: one line per call, and none of the subjects read above.
    log = os.path.expanduser("~/Library/Logs/Stow/mcp-audit.log")
    entries = [json.loads(line) for line in open(log)] if os.path.exists(log) else []
    ours = [e for e in entries if e.get("client") == "mcp-check 1"]
    calls = sum(len(v) for v in timings.values())
    content = open(log).read() if os.path.exists(log) else ""
    leaked = sum(1 for subject in subjects if subject in content)
    check("audit log has a line per call", len(ours) >= calls, f"{len(ours)} lines for {calls} calls")
    check("audit log holds no subject read in this check", leaked == 0, f"{len(subjects)} subjects checked")
    mode = oct(os.stat(log).st_mode & 0o777) if os.path.exists(log) else "missing"
    check("audit log is private (0600)", mode == "0o600", mode)

    for tool, took in timings.items():
        print(f"TIME  {tool}: {len(took)} calls, median {sorted(took)[len(took) // 2]:.0f} ms, slowest {max(took):.0f} ms")
    print(f"SIZE  largest reply {max(sizes.values())} characters")
    print(f"{results.count(True)} passed, {results.count(False)} failed")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
