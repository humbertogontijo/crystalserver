#!/usr/bin/env python3
"""idleot/ path resolver: MOVE vs PATCH by extension.

Layout:
  apps/<app>/idleot/<relpath>
  → apps/<app>/<relpath>   (strip behavior suffix)

Behaviors (by suffix):
  .patch   → PATCH  (dest must exist on upstream)
  .append  → APPEND (dest must exist)
  other    → MOVE   (dest must NOT exist on upstream)

Overlay dests (contain /idleot/ or match overlay roots) land in runtime
datapack / prepare links — never committed into stock submodule paths.
OTClient still uses mods/custom, modules/custom, data/custom (REPLACE_MODULES).
"""
from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any, Iterator, NamedTuple

APPS = ("crystalserver", "otclient")
BEHAVIOR_SUFFIXES = (".patch", ".append")
META_NAMES = frozenset(
    {
        "README.md",
        "aliases.yml",
        "aliases.yaml",
        "index.yml",
        "index.yaml",
        ".gitkeep",
    }
)
ALLOWED_DOTFILES = frozenset(
    {
        ".gitignore",
        ".gitignore.patch",
        ".dockerignore",
        ".dockerignore.patch",
    }
)
SKIP_TOP_DIRS = frozenset({"engine-custom"})

# Destinations that are runtime overlays (never fork-committed as stock paths).
OVERLAY_PREFIXES = (
    "lib/idleot/",
    "scripts/idleot/",
    "scripts/custom_migrations/",
    "npc/idleot/",
    "data-global/lib/idleot/",
    "data-global/scripts/idleot/",
    "data-global/npc/idleot/",
    "mods/custom/",
    "modules/custom/",
    "data/custom/",
    "branding/",
)

# Crystal datapack overlay may omit data-global/ in authoring paths.
CRYSTAL_DATAPACK_PREFIXES = (
    "lib/idleot/",
    "scripts/idleot/",
    "scripts/custom_migrations/",
    "npc/idleot/",
    "tibia/",
)


class FeatureEntry(NamedTuple):
    feature: str
    app: str
    source: Path  # absolute path under apps/<app>/idleot/
    dest: str  # relative to apps/<app>/ (behavior suffix stripped)
    behavior: str  # move | patch | append
    overlay: bool


def idleot_dir(root: Path, app: str) -> Path:
    env = os.environ.get("IDLEOT_APP_ROOT", "").strip()
    if env:
        env_p = Path(env)
        p = env_p / "idleot"
        if p.is_dir() and (env_p.name == app or env_p.name not in APPS):
            return p
    nested = Path(root) / "apps" / app / "idleot"
    if nested.is_dir():
        return nested
    local = Path(root) / "idleot"
    if local.is_dir() and Path(root).name == app:
        return local
    return nested


def behavior_of(path: Path) -> tuple[str, str]:
    """Return (behavior, dest_relpath_with_suffix_stripped) from filename."""
    name = path.name
    if name.endswith(".patch"):
        return "patch", name[: -len(".patch")]
    if name.endswith(".append"):
        return "append", name[: -len(".append")]
    return "move", name


def is_overlay_dest(dest: str, app: str) -> bool:
    d = dest.replace("\\", "/")
    for p in OVERLAY_PREFIXES:
        if d.startswith(p) or f"/{p}" in f"/{d}":
            return True
    if app == "crystalserver":
        for p in CRYSTAL_DATAPACK_PREFIXES:
            if d.startswith(p):
                return True
        if d.startswith("migrations/") or d.endswith(".product"):
            return True
        if d == "lib/lib.lua":
            return True
    return False


def walk_idleot_app(root: Path, app: str) -> Iterator[FeatureEntry]:
    idleot = idleot_dir(root, app)
    if not idleot.is_dir():
        return
    for dirpath, dirnames, filenames in os.walk(idleot):
        rel_dir = Path(dirpath).relative_to(idleot).as_posix()
        if rel_dir == ".":
            dirnames[:] = [d for d in dirnames if d not in SKIP_TOP_DIRS and not d.startswith(".")]
        else:
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for fn in filenames:
            if fn in META_NAMES:
                continue
            if fn.startswith(".") and fn not in ALLOWED_DOTFILES:
                continue
            src = Path(dirpath) / fn
            rel = src.relative_to(idleot).as_posix()
            if any(part in META_NAMES for part in Path(rel).parts):
                continue
            behavior, dest_leaf = behavior_of(Path(rel))
            dest_dir = str(Path(rel).parent)
            if dest_dir in (".", ""):
                dest = dest_leaf
            else:
                dest = f"{dest_dir}/{dest_leaf}".replace("\\", "/")
            yield FeatureEntry(
                feature="idleot",
                app=app,
                source=src.resolve(),
                dest=dest,
                behavior=behavior,
                overlay=is_overlay_dest(dest, app),
            )


def walk_feature_entries(root: Path) -> list[FeatureEntry]:
    """Walk apps/<app>/idleot/. `root` is the monorepo root or an engine checkout."""
    root = Path(root)
    entries: list[FeatureEntry] = []
    for app in APPS:
        entries.extend(walk_idleot_app(root, app))
    return entries


def check_dest_uniqueness(entries: list[FeatureEntry]) -> list[str]:
    seen: dict[tuple[str, str], Path] = {}
    errors: list[str] = []
    for e in entries:
        key = (e.app, e.dest)
        if key in seen:
            errors.append(
                f"duplicate dest apps/{e.app}/{e.dest}: {seen[key]} and {e.source}"
            )
        else:
            seen[key] = e.source
    return errors


def parse_engine_index(path: Path) -> dict[str, Any]:
    """Parse apps/<engine>/idleot/index.yml (path_map + series, no engine wrapper)."""
    text = path.read_text(encoding="utf-8") if path.is_file() else ""
    meta: dict[str, Any] = {
        "upstream": "",
        "base_sha": "",
        "series": [],
        "path_map": {},
    }
    list_key: str | None = None
    cur_entry: dict[str, Any] | None = None
    in_path_map = False
    for line in text.splitlines():
        if re.match(r"^path_map:\s*$", line):
            in_path_map = True
            list_key = None
            cur_entry = None
            continue
        if in_path_map:
            pm = re.match(r"^  (\S+):\s+(\S+)\s*$", line)
            if pm:
                meta["path_map"][pm.group(1)] = pm.group(2)
                continue
            if re.match(r"^[a-z]", line) and not line.startswith(" "):
                in_path_map = False
            else:
                continue
        if re.match(r"^upstream:\s*", line):
            meta["upstream"] = line.split(":", 1)[1].strip()
            continue
        if re.match(r"^base_sha:\s*", line):
            meta["base_sha"] = line.split(":", 1)[1].strip()
            continue
        if re.match(r"^series:\s*$", line):
            list_key = "series"
            continue
        if list_key == "series":
            m = re.match(r"^  - id:\s*(\S+)\s*$", line)
            if m:
                if cur_entry:
                    meta["series"].append(cur_entry)
                cur_entry = {
                    "id": m.group(1),
                    "class": "product",
                    "role": "",
                    "summary": "",
                    "paths": [],
                    "symbols": [],
                    "feature": "",
                }
                continue
            if cur_entry is None:
                continue
            if re.match(r"^    class:\s*", line):
                cur_entry["class"] = line.split(":", 1)[1].strip()
            elif re.match(r"^    role:\s*", line):
                cur_entry["role"] = line.split(":", 1)[1].strip()
            elif re.match(r"^    summary:\s*", line):
                cur_entry["summary"] = line.split(":", 1)[1].strip()
            elif re.match(r"^    feature:\s*", line):
                cur_entry["feature"] = line.split(":", 1)[1].strip()
            elif re.match(r"^    paths:\s*$", line):
                list_key = "paths"
            elif re.match(r"^    symbols:\s*$", line):
                list_key = "symbols"
            continue
        if list_key in ("paths", "symbols") and cur_entry is not None:
            pm = re.match(r"^      -\s+(.+?)\s*$", line)
            if pm:
                cur_entry[list_key].append(pm.group(1).strip().strip("'\""))
                continue
            m = re.match(r"^  - id:\s*(\S+)\s*$", line)
            if m:
                meta["series"].append(cur_entry)
                cur_entry = {
                    "id": m.group(1),
                    "class": "product",
                    "role": "",
                    "summary": "",
                    "paths": [],
                    "symbols": [],
                    "feature": "",
                }
                list_key = "series"
                continue
            if re.match(r"^    \w+:", line):
                list_key = "series"
                if re.match(r"^    class:\s*", line):
                    cur_entry["class"] = line.split(":", 1)[1].strip()
                elif re.match(r"^    feature:\s*", line):
                    cur_entry["feature"] = line.split(":", 1)[1].strip()
                elif re.match(r"^    summary:\s*", line):
                    cur_entry["summary"] = line.split(":", 1)[1].strip()
                elif re.match(r"^    role:\s*", line):
                    cur_entry["role"] = line.split(":", 1)[1].strip()
                elif re.match(r"^    paths:\s*$", line):
                    list_key = "paths"
                elif re.match(r"^    symbols:\s*$", line):
                    list_key = "symbols"
    if cur_entry:
        meta["series"].append(cur_entry)
    return meta


def parse_index_yml(path: Path) -> dict[str, Any]:
    """Load combined index from apps/*/idleot/index.yml.

    `path` may be the monorepo root or an engine idleot/index.yml.
    """
    path = Path(path)
    meta: dict[str, Any] = {
        "crystalserver": {"upstream": "", "base_sha": "", "series": []},
        "otclient": {"upstream": "", "base_sha": "", "series": []},
        "path_map": {},
    }

    def merge_engine(app: str, eng: dict[str, Any]) -> None:
        meta[app]["upstream"] = eng.get("upstream") or ""
        meta[app]["base_sha"] = eng.get("base_sha") or ""
        meta[app]["series"] = eng.get("series") or []
        for k, v in (eng.get("path_map") or {}).items():
            key = k if k.startswith(f"{app}/") else f"{app}/{k}"
            meta["path_map"][key] = v

    if path.name == "index.yml" and path.parent.name == "idleot":
        app = path.parent.parent.name
        if app in APPS:
            merge_engine(app, parse_engine_index(path))
        return meta

    root = path.parent if path.name == "index.yml" else path
    for app in APPS:
        merge_engine(app, parse_engine_index(idleot_dir(root, app) / "index.yml"))
    return meta


def feature_for_path(index: dict[str, Any], engine: str, relpath: str) -> str:
    """Resolve a label for an engine relative path (docs/export grouping)."""
    pm = index.get("path_map") or {}
    best = ""
    best_feat = ""
    for key, feat in pm.items():
        k = key
        if k.startswith(f"{engine}/"):
            k = k[len(engine) + 1 :]
        if relpath == k or relpath.startswith(k.rstrip("/") + "/") or (
            k.endswith("/") and relpath.startswith(k)
        ):
            if len(k) > len(best):
                best = k
                best_feat = feat
        if relpath == k:
            return feat
    if best_feat:
        return best_feat
    for e in index.get(engine, {}).get("series") or []:
        feat = e.get("feature") or e.get("id") or "idleot"
        for p in e.get("paths") or []:
            if relpath == p or relpath.startswith(p.rstrip("/") + "/") or (
                p.endswith("/") and relpath.startswith(p)
            ):
                return feat
    return "idleot"


def expand_paths_from_diff(repo: str, base_ref: str, pathspecs: list[str]) -> list[str]:
    """Return concrete file paths that differ under the given pathspecs."""
    import subprocess

    if not pathspecs:
        return []
    cmd = ["git", "-C", repo, "diff", "--name-only", base_ref, "--"] + pathspecs
    out = subprocess.check_output(cmd, text=True)
    return [p for p in out.splitlines() if p.strip()]


def series_allowlist(root: str | Path, engine: str, base_ref: str = "upstream/main") -> list[str]:
    """Flatten idleot/index.yml pathspecs + concrete idleot dest files."""
    root_s = str(root)
    index = parse_index_yml(Path(root_s))
    if engine == "crystalserver":
        repo = os.path.join(root_s, "apps", "crystalserver")
    elif engine == "otclient":
        repo = os.path.join(root_s, "apps", "otclient")
    else:
        raise ValueError(engine)

    files: set[str] = set()
    for e in index.get(engine, {}).get("series") or []:
        for p in expand_paths_from_diff(repo, base_ref, e.get("paths") or []):
            files.add(p)

    for entry in walk_feature_entries(Path(root_s)):
        if entry.app != engine or entry.overlay:
            continue
        if entry.dest.startswith("data/") or entry.dest.startswith("data-global/"):
            continue
        files.add(entry.dest)
    return sorted(files)


_DIFF_GIT_RE = re.compile(rb"^diff --git a/(.+?) b/(.+)$", re.M)


def git_has_blob(repo: str | Path, ref: str, dest: str) -> bool:
    import subprocess

    return (
        subprocess.call(
            ["git", "-C", str(repo), "cat-file", "-e", f"{ref}:{dest}"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        == 0
    )


def patch_git_paths(patch_bytes: bytes) -> list[str]:
    """Return dest paths named in `diff --git a/X b/Y` headers."""
    return [m.group(2).decode("utf-8", "replace") for m in _DIFF_GIT_RE.finditer(patch_bytes)]


def check_patches_apply(repo: str | Path, entries: list[FeatureEntry], ref: str) -> list[str]:
    """`git apply --check` each overlay .patch against dest blobs at `ref`.

    Uses `git show` into a temp tree so sparse-checkout / missing worktree
    files (data-global) still validate. Corrupt or stale hunks fail.
    """
    import subprocess
    import tempfile

    repo_s = str(repo)
    errors: list[str] = []
    for e in entries:
        if e.behavior != "patch":
            continue
        raw = Path(e.source).read_bytes()
        idx = raw.find(b"diff --git")
        if idx < 0:
            if raw.lstrip().startswith(b"# empty"):
                continue
            errors.append(f"no diff --git in {e.source}")
            continue
        body = raw[idx:]
        dests = patch_git_paths(body) or [e.dest]
        with tempfile.TemporaryDirectory(prefix="idleot-patch-") as td:
            td_path = Path(td)
            missing = False
            for dest in dests:
                show = subprocess.run(
                    ["git", "-C", repo_s, "show", f"{ref}:{dest}"],
                    capture_output=True,
                )
                if show.returncode != 0:
                    errors.append(
                        f"PATCH dest missing on {ref}: {dest} (from {e.source})"
                    )
                    missing = True
                    continue
                out = td_path / dest
                out.parent.mkdir(parents=True, exist_ok=True)
                out.write_bytes(show.stdout)
            if missing:
                continue
            with tempfile.NamedTemporaryFile("wb", suffix=".patch", delete=False) as fh:
                fh.write(body)
                tmp = fh.name
            try:
                r = subprocess.run(
                    ["git", "apply", "--check", "--whitespace=nowarn", tmp],
                    cwd=td,
                    capture_output=True,
                    text=True,
                )
                skipped = "Skipped patch" in (r.stdout or "") or "Skipped patch" in (
                    r.stderr or ""
                )
                if r.returncode != 0 or skipped:
                    err = (r.stderr or r.stdout or "apply --check failed").strip()
                    errors.append(f"PATCH does not apply on {ref}: {e.source}\n{err}")
            finally:
                os.unlink(tmp)
    return errors


if __name__ == "__main__":
    import json
    import sys

    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    ents = walk_feature_entries(root)
    print(
        json.dumps(
            [
                {
                    "feature": e.feature,
                    "app": e.app,
                    "dest": e.dest,
                    "behavior": e.behavior,
                    "overlay": e.overlay,
                    "source": str(e.source),
                }
                for e in ents
            ],
            indent=2,
        )
    )
