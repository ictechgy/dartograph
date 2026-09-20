#!/usr/bin/env python3
"""저장소 데모를 실행하고 asciinema v2 cast와 SVG 미리보기를 기록한다.

명령과 기대 종료 코드를 한곳에 둬서 README 데모를 출력 복사 없이 같은
fixture에서 다시 만들 수 있게 한다. cast의 재생 간격은 실제 실행 결과를
읽을 수 있게 조정한 값이다.
"""

from __future__ import annotations

import argparse
import html
import json
import re
import subprocess
import textwrap
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = "fixtures/closed_app"
SYMBOL = "project:lib/public_api.dart::PublicOnly"
QUERY_SYMBOL = "project:bin/main.dart::main"


def run_demo(name: str, arguments: list[str], expected_code: int) -> dict[str, object]:
    command = ["dart", "run", "bin/dartograph.dart", *arguments]
    completed = subprocess.run(
        command,
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    output = completed.stdout
    if completed.stderr:
        output += completed.stderr
    output = re.sub(r"\x1b\[[0-9;]*[mK]", "", output).replace("\r\n", "\n")
    if completed.returncode != expected_code:
        raise SystemExit(
            f"{name}: expected exit {expected_code}, got {completed.returncode}\n{output}"
        )
    return {
        "name": name,
        "command": command,
        "arguments": arguments,
        "exit_code": completed.returncode,
        "output": output.rstrip("\n"),
    }


def query_summary(record: dict[str, object]) -> list[str]:
    document = json.loads(str(record["output"]))
    result = document["result"]
    subject = result["subject"]["qualifiedName"]
    reachability = result["reachability"]
    members = [member["qualifiedName"] for member in result["members"]]
    return [
        f"status: {document['status']}",
        f"subject: {subject}",
        f"reachability: {reachability['state']} (reason: {reachability['reason']})",
        f"evidence path: {' -> '.join(reachability['path'])}",
        f"member: {members[0]}" if members else "member: none",
    ]


def impact_summary(record: dict[str, object]) -> list[str]:
    lines = str(record["output"]).splitlines()
    wanted = ("changed:", "risk:", "impacted:", "  project:", "    path:")
    return [line for line in lines if line.startswith(wanted)]


def dead_summary(record: dict[str, object]) -> list[str]:
    lines = str(record["output"]).splitlines()
    wanted = ("dead:", "limitation: closed-app:")
    return [line for line in lines if line.startswith(wanted)]


def cast_events(records: list[dict[str, object]]) -> list[list[object]]:
    events: list[list[object]] = []
    elapsed = 0.0
    for record in records:
        command = " ".join(record["command"])
        events.append([elapsed, "o", f"$ {command}\r\n"])
        elapsed += 0.04
        output_lines = str(record["output"]).splitlines()
        if record["name"] == "query":
            output_lines += [
                "",
                "# parsed evidence summary",
                *query_summary(record),
            ]
        for line in output_lines:
            events.append([elapsed, "o", f"{line}\r\n"])
            elapsed += 0.22
        events.append([elapsed, "o", f"[exit {record['exit_code']}]\r\n"])
        elapsed += 1.5
    return events


def svg_preview(records: list[dict[str, object]]) -> str:
    lines = [
        "dartograph demo  /  fixtures/closed_app",
        "",
        "$ " + " ".join(records[0]["command"]),
        *dead_summary(records[0]),
        "",
        "$ " + " ".join(records[1]["command"]),
        *impact_summary(records[1]),
        "",
        "$ " + " ".join(records[2]["command"]),
        *query_summary(records[2]),
    ]
    line_height = 22
    wrapped_lines = [
        part
        for line in lines
        for part in (
            textwrap.wrap(
                line,
                width=106,
                break_long_words=False,
                break_on_hyphens=False,
            )
            or [""]
        )
    ]
    height = 64 + line_height * len(wrapped_lines)
    text_lines: list[str] = []
    for index, line in enumerate(wrapped_lines):
        color = "#8be9fd" if line.startswith("$") else "#f8f8f2"
        if line.startswith("dead:") or line.startswith("status:"):
            color = "#50fa7b"
        text_lines.append(
            f'<text x="32" y="{60 + index * line_height}" fill="{color}">{html.escape(line)}</text>'
        )
    return """<svg xmlns="http://www.w3.org/2000/svg" width="1120" height="%d" viewBox="0 0 1120 %d" role="img" aria-labelledby="title desc">
  <title id="title">dartograph evidence query demo</title>
  <desc id="desc">A terminal summary showing dead code, impact, and parsed query evidence for the closed app fixture. The linked cast contains the full command output.</desc>
  <rect width="1120" height="%d" rx="14" fill="#282a36"/>
  <circle cx="28" cy="26" r="7" fill="#ff5555"/><circle cx="52" cy="26" r="7" fill="#f1fa8c"/><circle cx="76" cy="26" r="7" fill="#50fa7b"/>
  <g font-family="SFMono-Regular,Consolas,Menlo,monospace" font-size="16">%s</g>
</svg>
""" % (height, height, height, "\n".join(text_lines))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=ROOT / "doc/assets/demo",
        help="directory for dartograph-demo.cast and preview.svg",
    )
    args = parser.parse_args()
    records = [
        run_demo(
            "dead",
            ["dead", "--closed-app", "--format", "text", FIXTURE],
            expected_code=1,
        ),
        run_demo(
            "impact",
            ["impact", "--symbol", SYMBOL, "--format", "text", FIXTURE],
            expected_code=0,
        ),
        run_demo(
            "query",
            ["query", QUERY_SYMBOL, FIXTURE],
            expected_code=0,
        ),
    ]

    args.output_dir.mkdir(parents=True, exist_ok=True)
    cast = {
        "version": 2,
        "width": 132,
        "height": 36,
        "timestamp": int(time.time()),
        "env": {"TERM": "xterm-256color"},
    }
    cast_lines = [json.dumps(cast, separators=(",", ":"))]
    cast_lines.extend(json.dumps(event, ensure_ascii=False, separators=(",", ":")) for event in cast_events(records))
    (args.output_dir / "dartograph-demo.cast").write_text("\n".join(cast_lines) + "\n")
    (args.output_dir / "preview.svg").write_text(svg_preview(records))
    print(f"recorded {len(records)} commands to {args.output_dir}")
    print("exit codes: " + ", ".join(str(record["exit_code"]) for record in records))


if __name__ == "__main__":
    main()
