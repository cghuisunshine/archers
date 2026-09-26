#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export EPISODE_TEMPLATE="$SCRIPT_DIR/sunday-episode.html"

python3 - "$@" <<'PY'
import argparse
from collections import Counter
from datetime import date, datetime, timedelta, timezone
import html
import os
from pathlib import Path
import re
import filecmp
import shutil
import subprocess
from urllib.parse import quote


DAYS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")


def timestamp_seconds(value):
    match = re.fullmatch(r"(?:(\d+)h\s*)?(?:(\d+)m\s*)?(\d+)s", value)
    if not match:
        raise ValueError(f"Invalid timestamp: {value}")
    hours, minutes, seconds = (int(part or 0) for part in match.groups())
    if seconds >= 60 or (hours and minutes >= 60):
        raise ValueError(f"Invalid timestamp: {value}")
    return hours * 3600 + minutes * 60 + seconds


def parse_text_transcript(source):
    header = re.compile(r"^(.+?)\s+\(((?:\d+h\s*)?(?:\d+m\s*)?\d+s)\):\s*$")
    entries = []
    speaker = None
    timestamp = None
    lines = []

    for line_number, line in enumerate(source.splitlines(), 1):
        match = header.fullmatch(line.strip())
        if match:
            if speaker is not None:
                entries.append((speaker, timestamp, "\n".join(lines).strip()))
            speaker, label = match.groups()
            timestamp = timestamp_seconds(label)
            if entries and timestamp < entries[-1][1]:
                raise ValueError(f"Line {line_number}: timestamps must be in order")
            lines = []
        elif speaker is None:
            if line.strip():
                raise ValueError(f"Line {line_number}: expected a header like 'George (1m 12s):'")
        else:
            lines.append(line)

    if speaker is not None:
        entries.append((speaker, timestamp, "\n".join(lines).strip()))
    if not entries:
        raise ValueError("No timestamped passages found")
    return entries


def srt_time_ms(value):
    match = re.fullmatch(r"(\d{2,}):([0-5]\d):([0-5]\d)[,.](\d{3})", value)
    if not match:
        raise ValueError(f"Invalid SRT timestamp: {value}")
    hours, minutes, seconds, milliseconds = map(int, match.groups())
    return ((hours * 60 + minutes) * 60 + seconds) * 1000 + milliseconds


def parse_srt(source):
    timing = re.compile(
        r"^(\d{2,}:[0-5]\d:[0-5]\d[,.]\d{3})\s*-->\s*"
        r"(\d{2,}:[0-5]\d:[0-5]\d[,.]\d{3})(?:\s+.*)?$"
    )
    entries = []
    previous_start_ms = None
    for number, block in enumerate(re.split(r"\n\s*\n", source.strip()), 1):
        lines = block.splitlines()
        if lines and lines[0].strip().isdigit():
            lines.pop(0)
        match = timing.fullmatch(lines[0].strip()) if lines else None
        if not match:
            raise ValueError(f"SRT cue {number}: expected a timestamp range")
        start_ms, end_ms = (srt_time_ms(value) for value in match.groups())
        if end_ms <= start_ms:
            raise ValueError(f"SRT cue {number}: end must be after start")
        if previous_start_ms is not None and start_ms < previous_start_ms:
            raise ValueError(f"SRT cue {number}: timestamps must be in order")
        previous_start_ms = start_ms
        body = " ".join(line.strip() for line in lines[1:] if line.strip())
        if body:
            entries.append(("Caption", start_ms / 1000, body))
    if not entries:
        raise ValueError("No SRT captions found")
    return entries


def replace_once(page, pattern, replacement):
    page, count = re.subn(pattern, lambda _: replacement, page, count=1, flags=re.S)
    if count != 1:
        raise ValueError(f"The Sunday page template is missing {pattern!r}")
    return page


def episode_day(source):
    # The programme announcement is much more reliable than weekdays mentioned in dialogue.
    pattern = r"\b(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)(?:['’]s)?\s+episode\s+of\s+(?:the\s+)?Archers\b"
    found = {match.capitalize() for match in re.findall(pattern, source, flags=re.I)}
    if len(found) == 1:
        return found.pop()
    if found:
        raise ValueError("Conflicting episode days in the transcript; use --day")
    raise ValueError("Could not find an episode-day announcement in the transcript; use --day")


def episode_date(day, transcript, audio, specified_date):
    if specified_date:
        try:
            chosen = date.fromisoformat(specified_date)
        except ValueError as exc:
            raise ValueError("--date must be YYYY-MM-DD") from exc
        if chosen.weekday() != DAYS.index(day):
            raise ValueError(f"{chosen} is {DAYS[chosen.weekday()]}, but the transcript says {day}")
        return chosen

    named_date = re.match(r"(\d{2})_(\d{2})_(\d{4})(?:\D|$)", transcript.name)
    if named_date:
        day_number, month, year = map(int, named_date.groups())
        try:
            chosen = date(year, month, day_number)
        except ValueError as exc:
            raise ValueError(f"Invalid date in transcript filename: {transcript.name}") from exc
        if chosen.weekday() != DAYS.index(day):
            raise ValueError(f"Transcript filename says {chosen} ({DAYS[chosen.weekday()]}), but the episode says {day}")
        return chosen

    # Existing audio names end with a Unix timestamp recording the release date.
    match = re.search(r"-(\d{10})\.[^.]+$", audio.name)
    anchor = date.today()
    if match:
        stamped = datetime.fromtimestamp(int(match.group(1)), timezone.utc).date()
        if date(2000, 1, 1) <= stamped <= date(2100, 1, 1):
            anchor = stamped
    return anchor - timedelta(days=(anchor.weekday() - DAYS.index(day)) % 7)


def archive_filename(chosen_date, archive_dir):
    # Existing pages use 060922.html / 060923.html for September 2026.
    # Preserve their two-digit archive prefix when it is unambiguous.
    prefixes = Counter(
        path.stem[:2] for path in archive_dir.glob("[0-9][0-9][0-9][0-9][0-9][0-9].html")
        if 1 <= int(path.stem[2:4]) <= 12 and 1 <= int(path.stem[4:]) <= 31
    )
    prefix = prefixes.most_common(1)[0][0] if prefixes else chosen_date.strftime("%y")
    return f"{prefix}{chosen_date:%m%d}.html"


def git(repo, *args):
    command = ["git", "-C", str(repo), *args]
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"{' '.join(command)} failed: {detail}")
    return result.stdout.strip()


def repo_path(path, repo):
    try:
        return path.relative_to(repo).as_posix()
    except ValueError as exc:
        raise ValueError(f"File must be inside the Git repository: {path}") from exc


def update_index(index_path, output, day, chosen_date):
    page = index_path.read_text(encoding="utf-8")
    href = quote(os.path.relpath(output, index_path.parent).replace(os.sep, "/"), safe="/")
    label = html.escape(f"{day}’s episode — {chosen_date.day} {chosen_date:%B %Y}")
    link = f'<li><a href="{html.escape(href, quote=True)}">{label}</a></li>'
    pattern = rf'<li><a href="{re.escape(href)}">.*?</a></li>'
    if re.search(pattern, page, flags=re.S):
        page = re.sub(pattern, lambda _: link, page, count=1, flags=re.S)
    elif "<ul>" in page:
        page = page.replace("<ul>", f"<ul>\n{link}", 1)
    else:
        raise ValueError(f"Archive index has no <ul> for episode links: {index_path}")
    index_path.write_text(page, encoding="utf-8")


def publish(repo, audio, output, index_path, chosen_date):
    paths = [repo_path(path, repo) for path in (audio, output, index_path)]
    git(repo, "add", "--", *paths)
    changed = subprocess.run(
        ["git", "-C", str(repo), "diff", "--cached", "--quiet", "HEAD", "--", *paths]
    ).returncode
    if changed not in (0, 1):
        raise RuntimeError("Could not inspect the staged episode files")
    if changed:
        git(repo, "commit", "--only", "-m", f"Publish The Archers episode for {chosen_date}", "--", *paths)
    branch = git(repo, "symbolic-ref", "--quiet", "--short", "HEAD")
    git(repo, "push", "origin", branch)
    print(f"Pushed {', '.join(paths)} to origin/{branch}")


def main():
    parser = argparse.ArgumentParser(
        description="Create an audio-synced episode page from a timestamped transcript."
    )
    parser.add_argument("transcript", type=Path, help="SRT file or text file with 'Speaker (1m 12s):' headers")
    parser.add_argument("audio", type=Path, help="Audio file played by the page")
    parser.add_argument("output", nargs="?", type=Path, help="Output HTML (default: archive date filename)")
    parser.add_argument("--title", help="Page heading (default: weekday’s episode)")
    parser.add_argument("--day", choices=DAYS, help="Episode day if the transcript has no announcement")
    parser.add_argument("--date", help="Episode date in YYYY-MM-DD format (overrides automatic date matching)")
    args = parser.parse_args()

    template = Path(os.environ["EPISODE_TEMPLATE"]).resolve()
    repo = template.parent
    try:
        if Path(git(repo, "rev-parse", "--show-toplevel")).resolve() != repo:
            raise ValueError(f"Script must be at the root of its Git repository: {repo}")
        git(repo, "remote", "get-url", "--push", "origin")
        git(repo, "symbolic-ref", "--quiet", "--short", "HEAD")
    except (RuntimeError, ValueError) as exc:
        parser.error(str(exc))

    transcript = args.transcript.resolve()
    audio = args.audio.resolve()
    if not transcript.is_file():
        parser.error(f"Transcript not found: {transcript}")
    if not audio.is_file():
        parser.error(f"Audio not found: {audio}")
    try:
        source = transcript.read_text(encoding="utf-8-sig")
        entries = parse_srt(source) if transcript.suffix.lower() == ".srt" else parse_text_transcript(source)
        day = args.day or episode_day(" ".join(body for _, _, body in entries))
        chosen_date = episode_date(day, transcript, audio, args.date)
        default_output = transcript.with_name(archive_filename(chosen_date, repo)) if transcript.is_relative_to(repo) else repo / archive_filename(chosen_date, repo)
        output = (args.output or default_output).resolve()
        repo_path(output, repo)
        if output == template:
            raise ValueError("Choose an output name other than sunday-episode.html (the template)")
        if output == audio or output == transcript:
            raise ValueError("Output must be a different file from the inputs")
        if not audio.is_relative_to(repo):
            published_audio = repo / audio.name
            if published_audio.exists() and not filecmp.cmp(audio, published_audio, shallow=False):
                raise ValueError(f"A different audio file already exists at {published_audio}")
        else:
            published_audio = audio
        page = template.read_text(encoding="utf-8")
        title = args.title or f"{day}’s episode"
        safe_title = html.escape(title)
        relative_audio = os.path.relpath(published_audio, output.parent).replace(os.sep, "/")
        audio_url = html.escape(quote(relative_audio, safe="/"), quote=True)
        transcript_html = "\n\n".join(
            f'<strong data-start="{seconds:.3f}">{html.escape(speaker)} '
            f'({int(seconds) // 60}m {int(seconds) % 60}s)</strong>\n'
            f"{html.escape(body)}"
            for speaker, seconds, body in entries
        )
        browser_title = f"The Archers — {day} Transcript" if not args.title else f"The Archers — {title} Transcript"
        page = replace_once(page, r"<title>.*?</title>", f"<title>{html.escape(browser_title)}</title>")
        page = replace_once(page, r"<h1>.*?</h1>", f"<h1>{safe_title}</h1>")
        page = replace_once(page, r'<p class="meta">.*?</p>', '<p class="meta">Transcript with timestamps</p>')
        page = replace_once(page, r'<section class="player" id="player" aria-label="[^"]*">',
                            f'<section class="player" id="player" aria-label="{html.escape(title + " audio", quote=True)}">')
        page = replace_once(page, r'<audio id="episode-audio".*?</audio>',
                            f'<audio id="episode-audio" controls preload="metadata" src="{audio_url}">'
                            f'Your browser does not support audio playback. <a href="{audio_url}">Download the audio</a>.</audio>')
        page = replace_once(page, r'<p id="audio-error".*?</p>',
                            '<p id="audio-error" role="alert" hidden>Unable to load the recording. Check that the audio file is still at its original location.</p>')
        page = replace_once(page, r'<div class="transcript">.*?</div>\s*</article>',
                            f'<div class="transcript">{transcript_html}</div>\n</article>')
        page = replace_once(page, r'const start = Number\(match\[1\] \|\| 0\) \* 60 \+ Number\(match\[2\]\);',
                            'const start = Number(node.dataset.start);')
    except (OSError, UnicodeError, ValueError) as exc:
        parser.error(str(exc))

    output.parent.mkdir(parents=True, exist_ok=True)
    if published_audio != audio and not published_audio.exists():
        shutil.copy2(audio, published_audio)
    output.write_text(page, encoding="utf-8")
    print(f"Created {output} for {chosen_date} ({day}) with {len(entries)} timestamped passages")
    try:
        index_path = repo / "index.html"
        update_index(index_path, output, day, chosen_date)
        publish(repo, published_audio, output, index_path, chosen_date)
    except (OSError, UnicodeError, ValueError, RuntimeError) as exc:
        raise SystemExit(f"Episode files were created locally, but publishing failed: {exc}") from exc


if __name__ == "__main__":
    main()
PY
