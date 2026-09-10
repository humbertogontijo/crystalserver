#!/usr/bin/env python3
"""Parse Crystal spell and potion Lua into the combat-automation catalog."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CRYSTAL = HERE.parents[1]
# Umbrella checkout: <root>/apps/crystalserver. A standalone Crystal checkout
# uses its parent as the optional umbrella, and simply has no OTC IDs if absent.
UMBRELLA = CRYSTAL.parent.parent if CRYSTAL.parent.name == "apps" else CRYSTAL.parent

SPELLS_ROOT = CRYSTAL / "data/scripts/spells"
POTIONS = CRYSTAL / "data/scripts/actions/items/potions.lua"
REGISTER_SPELLS = CRYSTAL / "data/scripts/lib/register_spells.lua"
LUA_CONFIG = CRYSTAL / "data-global/lib/idleot/combat_automation/01_config.lua"
SPELL_INFO = UMBRELLA / "packages/asset-pipeline/data/spellInfo.generated.json"

# Matches Crystal Direction enum (position.hpp).
DIR_NORTH, DIR_EAST, DIR_SOUTH, DIR_WEST = 0, 1, 2, 3
DIR_SOUTHWEST, DIR_SOUTHEAST, DIR_NORTHWEST, DIR_NORTHEAST = 4, 5, 6, 7
DIR_STEP = {
    DIR_NORTH: (0, -1),
    DIR_EAST: (1, 0),
    DIR_SOUTH: (0, 1),
    DIR_WEST: (-1, 0),
    DIR_SOUTHWEST: (-1, 1),
    DIR_SOUTHEAST: (1, 1),
    DIR_NORTHWEST: (-1, -1),
    DIR_NORTHEAST: (1, -1),
}

BEGIN = "-- BEGIN GENERATED COMBAT AUTOMATION CATALOG"
END = "-- END GENERATED COMBAT AUTOMATION CATALOG"
SPELL_DIRS = ("healing", "attack", "support", "party", "familiar")

EXCLUDE_FILE_RE = re.compile(r"^(practise_|heal_monsters|heal_malice|#example|example)", re.I)
EXCLUDE_SUPPORT_FILES = {
    "light.lua",
    "great_light.lua",
    "magic_rope.lua",
    "find_fiend.lua",
}
PARTY_HEAL_WORDS = {"exura sio", "exura gran sio", "exura tio sio"}

BASE_ID_TO_VOCATIONS = {
    "SORCERER": ["sorcerer", "master sorcerer"],
    "DRUID": ["druid", "elder druid"],
    "PALADIN": ["paladin", "royal paladin"],
    "KNIGHT": ["knight", "elite knight"],
    "MONK": ["monk", "exalted monk"],
}

POTION_NAMES = {
    266: "Health Potion",
    268: "Mana Potion",
    236: "Strong Health Potion",
    237: "Strong Mana Potion",
    239: "Great Health Potion",
    238: "Great Mana Potion",
    7642: "Great Spirit Potion",
    7643: "Ultimate Health Potion",
    23373: "Ultimate Mana Potion",
    23374: "Ultimate Spirit Potion",
    23375: "Supreme Health Potion",
    53162: "Superior Mana Potion",
    53163: "Distilled Superior Mana Potion",
    53164: "Distilled Ultimate Mana Potion",
    7876: "Small Health Potion",
}


def words_to_id(words: str) -> str:
    value = re.sub(r"\s+", "_", words.strip().lower())
    return re.sub(r"[^a-z0-9_]", "", value)


def potion_name_to_id(name: str) -> str:
    value = re.sub(r"[^a-z0-9]+", "_", name.strip().lower())
    return value.strip("_")


def eval_lua_number_expr(raw: str) -> int | None:
    cleaned = re.sub(r"\s+", "", raw)
    if not cleaned or not re.fullmatch(r"[\d.*]+", cleaned):
        return None
    parts = cleaned.split("*")
    try:
        numbers = [float(part) for part in parts]
    except ValueError:
        return None
    product = 1.0
    for number in numbers:
        product *= number
    return int(product // 1)


def match_string_prop(src: str, prop: str) -> str | None:
    match = re.search(rf'spell:{re.escape(prop)}\(\s*"([^"]*)"\s*\)', src, re.I)
    return match.group(1) if match else None


def match_spell_groups(src: str) -> tuple[str | None, str | None]:
    multi = re.search(
        r'spell:group\(\s*"([^"]*)"\s*,\s*"([^"]*)"\s*\)', src, re.I
    )
    if multi:
        return multi.group(1).lower(), multi.group(2).lower()
    single = re.search(r'spell:group\(\s*"([^"]*)"\s*\)', src, re.I)
    return (single.group(1).lower(), None) if single else (None, None)


def match_number_prop(src: str, prop: str) -> int | None:
    match = re.search(rf"spell:{re.escape(prop)}\(\s*([^)]+)\s*\)", src, re.I)
    return eval_lua_number_expr(match.group(1).strip()) if match else None


def match_bool_prop(src: str, prop: str) -> bool:
    match = re.search(
        rf"spell:{re.escape(prop)}\(\s*(true|false|1|0)\s*\)", src, re.I
    )
    return bool(match and match.group(1).lower() in {"true", "1"})


def parse_vocations(src: str) -> list[str]:
    match = re.search(r"spell:vocation\(([^)]*)\)", src, re.I)
    if not match:
        return []
    out = []
    for value in re.findall(r'"([^"]+)"', match.group(1)):
        name = value.split(";", 1)[0].strip().lower()
        if name and name not in out:
            out.append(name)
    return out


def matching_brace_end(src: str, open_index: int) -> int:
    """Return index of the closing brace matching src[open_index]."""
    depth = 0
    for idx in range(open_index, len(src)):
        char = src[idx]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return idx
    return open_index


def parse_matrix_body(body: str) -> list[list[int]]:
    rows: list[list[int]] = []
    for row_match in re.finditer(r"\{([^{}]*)\}", body):
        cells = [int(value) for value in re.findall(r"\d+", row_match.group(1))]
        if cells:
            rows.append(cells)
    return rows


def parse_area_matrices(src: str) -> dict[str, list[list[int]]]:
    """Parse AREA_* / AREADIAGONAL_* tables from Lua source."""
    out: dict[str, list[list[int]]] = {}
    for match in re.finditer(r"(AREA(?:DIAGONAL)?[A-Z0-9_]*)\s*=\s*\{", src):
        name = match.group(1)
        start = match.end() - 1
        end = matching_brace_end(src, start)
        rows = parse_matrix_body(src[start : end + 1])
        if rows:
            out[name] = rows
    return out


def extract_inline_matrix(src: str) -> list[list[int]] | None:
    """Parse createCombatArea({ ... }) anonymous matrices."""
    match = re.search(r"createCombatArea\(\s*\{", src)
    if not match:
        return None
    start = match.end() - 1
    end = matching_brace_end(src, start)
    rows = parse_matrix_body(src[start : end + 1])
    return rows or None


_AREA_MATRICES: dict[str, list[list[int]]] | None = None


def area_matrices() -> dict[str, list[list[int]]]:
    global _AREA_MATRICES
    if _AREA_MATRICES is None:
        _AREA_MATRICES = parse_area_matrices(REGISTER_SPELLS.read_text(encoding="utf-8"))
    return _AREA_MATRICES


def matrix_offsets_from_center(matrix: list[list[int]]) -> list[tuple[int, int]]:
    center: tuple[int, int] | None = None
    for row_idx, row in enumerate(matrix):
        for col_idx, value in enumerate(row):
            if value in (2, 3):
                center = (col_idx, row_idx)
                break
        if center:
            break
    if not center:
        return []
    cx, cy = center
    offsets: list[tuple[int, int]] = []
    for row_idx, row in enumerate(matrix):
        for col_idx, value in enumerate(row):
            if value in (1, 3):
                offsets.append((col_idx - cx, row_idx - cy))
    return offsets


def rotate_offset(dx: int, dy: int, direction: int) -> tuple[int, int]:
    """Rotate a NORTH-oriented offset into another cardinal direction."""
    if direction == DIR_NORTH:
        return dx, dy
    if direction == DIR_EAST:
        return -dy, dx
    if direction == DIR_SOUTH:
        return -dx, -dy
    if direction == DIR_WEST:
        return dy, -dx
    return dx, dy


def mirror_offset(dx: int, dy: int) -> tuple[int, int]:
    return -dx, dy


def flip_offset(dx: int, dy: int) -> tuple[int, int]:
    return dx, -dy


def unique_sorted(offsets: list[tuple[int, int]]) -> list[tuple[int, int]]:
    return sorted(set(offsets))


def expand_direction_tiles(
    ortho: list[list[int]], diagonal: list[list[int]] | None
) -> dict[int, list[tuple[int, int]]]:
    """Caster-relative hit tiles per facing, matching AreaCombat setupArea/setupExtArea."""
    by_dir: dict[int, list[tuple[int, int]]] = {}
    north_from_center = matrix_offsets_from_center(ortho)
    for direction in (DIR_NORTH, DIR_EAST, DIR_SOUTH, DIR_WEST):
        step_x, step_y = DIR_STEP[direction]
        tiles = [
            (
                rotate_offset(dx, dy, direction)[0] + step_x,
                rotate_offset(dx, dy, direction)[1] + step_y,
            )
            for dx, dy in north_from_center
        ]
        by_dir[direction] = unique_sorted(tiles)

    if diagonal:
        nw_from_center = matrix_offsets_from_center(diagonal)
        nw_step = DIR_STEP[DIR_NORTHWEST]
        by_dir[DIR_NORTHWEST] = unique_sorted(
            [(dx + nw_step[0], dy + nw_step[1]) for dx, dy in nw_from_center]
        )
        ne_from_center = [mirror_offset(dx, dy) for dx, dy in nw_from_center]
        ne_step = DIR_STEP[DIR_NORTHEAST]
        by_dir[DIR_NORTHEAST] = unique_sorted(
            [(dx + ne_step[0], dy + ne_step[1]) for dx, dy in ne_from_center]
        )
        sw_from_center = [flip_offset(dx, dy) for dx, dy in nw_from_center]
        sw_step = DIR_STEP[DIR_SOUTHWEST]
        by_dir[DIR_SOUTHWEST] = unique_sorted(
            [(dx + sw_step[0], dy + sw_step[1]) for dx, dy in sw_from_center]
        )
        se_from_center = [mirror_offset(dx, dy) for dx, dy in sw_from_center]
        se_step = DIR_STEP[DIR_SOUTHEAST]
        by_dir[DIR_SOUTHEAST] = unique_sorted(
            [(dx + se_step[0], dy + se_step[1]) for dx, dy in se_from_center]
        )
    return by_dir


def collect_area_pairs(src: str) -> list[tuple[str, str]]:
    """Ordered unique (AREA_*, AREADIAGONAL_*|"") from createCombat(Area) calls."""
    pairs: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for match in re.finditer(
        r"createCombat(?:Area)?\(\s*(AREA[A-Z0-9_]+)\s*(?:,\s*(AREADIAGONAL[A-Z0-9_]+))?",
        src,
    ):
        pair = (match.group(1), match.group(2) or "")
        if pair not in seen:
            seen.add(pair)
            pairs.append(pair)
    return pairs


def detect_wod_gate(src: str) -> dict | None:
    match = re.search(r'getWheelSpellAdditionalArea\(\s*"([^"]+)"\s*\)', src)
    if match:
        return {"check": "additionalArea", "name": match.group(1)}
    match = re.search(r'instantSkillWOD\(\s*"([^"]+)"\s*\)', src)
    if match:
        return {"check": "instantSkill", "name": match.group(1)}
    if re.search(r"MAIN_AREAS\s*=", src):
        match = re.search(r'upgradeSpellsWOD\(\s*"([^"]+)"\s*\)', src)
        if match:
            return {"check": "upgradeGrade", "name": match.group(1)}
    return None


def pick_base_and_wod_pairs(
    pairs: list[tuple[str, str]],
) -> tuple[tuple[str, str] | None, tuple[str, str] | None]:
    if not pairs:
        return None, None
    base = next((pair for pair in pairs if "WOD" not in pair[0]), pairs[0])
    wod = next((pair for pair in pairs if "WOD" in pair[0]), None)
    if wod is None:
        for pair in pairs:
            if pair[0] != base[0]:
                wod = pair
                break
    return base, wod


def matrix_from_pair(
    pair: tuple[str, str] | None,
    global_mats: dict[str, list[list[int]]],
    local_mats: dict[str, list[list[int]]],
) -> tuple[list[list[int]] | None, list[list[int]] | None]:
    if not pair:
        return None, None
    return (
        resolve_matrix(pair[0], global_mats, local_mats),
        resolve_matrix(pair[1], global_mats, local_mats) if pair[1] else None,
    )


def parse_main_areas_list(src: str) -> list[str]:
    match = re.search(r"MAIN_AREAS\s*=\s*\{([^}]+)\}", src)
    if not match:
        return []
    return re.findall(r"\b(AREA[A-Z0-9_]+)\b", match.group(1))


def area_shape_from_name(area_name: str) -> str:
    if "BEAM" in area_name:
        return "beam"
    if "SQUAREWAVE" in area_name:
        return "squarewave"
    if "CIRCLE" in area_name:
        return "circle"
    if "SQUARE" in area_name:
        return "square"
    if "WAVE" in area_name or area_name:
        return "wave"
    return "single"


def extract_named_areas(src: str) -> tuple[str, str]:
    """Return (AREA_*, AREADIAGONAL_* or '') from createCombat(Area) or first identifiers."""
    pairs = collect_area_pairs(src)
    if pairs:
        base, _ = pick_base_and_wod_pairs(pairs)
        if base:
            return base[0], base[1]
    areas = [
        name
        for name in re.findall(r"\b(AREA[A-Z0-9_]+)\b", src)
        if "WOD" not in name
    ]
    diags = re.findall(r"\b(AREADIAGONAL[A-Z0-9_]+)\b", src)
    return (areas[0] if areas else ""), (diags[0] if diags else "")


def resolve_matrix(
    name: str, global_mats: dict[str, list[list[int]]], local_mats: dict[str, list[list[int]]]
) -> list[list[int]] | None:
    if not name:
        return None
    return global_mats.get(name) or local_mats.get(name)


def parse_spell_area(src: str, target_mode: str) -> dict:
    if target_mode == "friend":
        return {
            "kind": "friend",
            "shape": "single",
            "radius": 0,
        }

    need_direction = match_bool_prop(src, "needDirection")
    pairs = collect_area_pairs(src)
    base_pair, wod_pair = pick_base_and_wod_pairs(pairs)
    area_name = base_pair[0] if base_pair else ""
    diagonal_name = base_pair[1] if base_pair else ""
    if not area_name:
        area_name, diagonal_name = extract_named_areas(src)
        base_pair = (area_name, diagonal_name) if area_name else None

    matrices = area_matrices()
    local_mats = parse_area_matrices(src)
    sizes = re.findall(r"\d+", area_name)
    size = int(sizes[-1]) if sizes else 0
    ortho, diagonal = matrix_from_pair(base_pair, matrices, local_mats)
    if ortho is None:
        ortho = extract_inline_matrix(src)

    wod_gate = detect_wod_gate(src)
    wod_ortho, wod_diagonal = matrix_from_pair(wod_pair, matrices, local_mats)

    if target_mode == "enemy":
        chain = re.search(r"return\s+targets\s*,\s*(\d+)\s*,", src)
        chain_range = int(chain.group(1)) if chain else None
        shape = (
            "chain"
            if chain_range is not None
            else area_shape_from_name(area_name)
            if area_name
            else "single"
        )
        if shape not in {"chain", "circle", "square", "single"}:
            shape = "single"
        radius = (
            chain_range
            if chain_range is not None
            else size
            if shape in {"circle", "square"}
            else 0
        )
        area: dict = {
            "kind": "target",
            "shape": shape,
            "radius": radius,
        }
        if ortho and shape in {"circle", "square"}:
            area["tiles"] = unique_sorted(matrix_offsets_from_center(ortho))
        return area

    if need_direction:
        shape = area_shape_from_name(area_name) if area_name else "wave"
        if shape not in {"beam", "squarewave", "wave"}:
            shape = "wave"
        area = {
            "kind": "direction",
            "shape": shape,
            "radius": 0,
        }
        if wod_gate and wod_gate["check"] == "upgradeGrade":
            grade_areas = parse_main_areas_list(src)
            grade_by_dir: dict[int, dict[int, list[tuple[int, int]]]] = {}
            for index, grade_name in enumerate(grade_areas, start=1):
                grade_ortho = resolve_matrix(grade_name, matrices, local_mats)
                if grade_ortho:
                    grade_by_dir[index] = expand_direction_tiles(grade_ortho, None)
            if grade_by_dir:
                area["byDir"] = grade_by_dir[1]
                area["gradeByDir"] = grade_by_dir
                area["wod"] = wod_gate
            elif ortho:
                area["byDir"] = expand_direction_tiles(ortho, diagonal)
            return area

        if ortho:
            area["byDir"] = expand_direction_tiles(ortho, diagonal)
        if wod_gate and wod_ortho:
            area["wodByDir"] = expand_direction_tiles(wod_ortho, wod_diagonal)
            area["wod"] = wod_gate
        return area

    shape = area_shape_from_name(area_name) if area_name else "single"
    if shape not in {"circle", "square", "single"}:
        shape = "single"
    area = {
        "kind": "self",
        "shape": shape,
        "radius": max(0, size),
    }
    if ortho:
        area["tiles"] = unique_sorted(matrix_offsets_from_center(ortho))
        if area["tiles"] and area["radius"] == 0:
            area["radius"] = max(max(abs(dx), abs(dy)) for dx, dy in area["tiles"])
    if wod_gate and wod_ortho:
        area["wodTiles"] = unique_sorted(matrix_offsets_from_center(wod_ortho))
        area["wod"] = wod_gate
        area["wodRadius"] = max(max(abs(dx), abs(dy)) for dx, dy in area["wodTiles"])
    return area


def parse_spell_file(path: Path, src: str) -> dict | None:
    filename = path.name
    if EXCLUDE_FILE_RE.search(filename) or filename in EXCLUDE_SUPPORT_FILES:
        return None
    if not re.search(r'Spell\("instant"\)', src, re.I):
        return None

    words = match_string_prop(src, "words")
    name = match_string_prop(src, "name")
    if not words or not name:
        return None
    words_norm = words.strip().lower()
    has_player_name_param = bool(
        re.search(r"spell:hasPlayerNameParam\(\s*true", src, re.I)
    )
    is_party_heal = words_norm in PARTY_HEAL_WORDS
    if has_player_name_param and not is_party_heal:
        return None

    group_raw, secondary_group = match_spell_groups(src)
    if group_raw == "healing":
        group = "healing"
    elif group_raw == "attack":
        group = "attack"
    elif group_raw == "support":
        if secondary_group == "stance":
            group = "stance"
        elif words_norm == "utamo vita":
            group = "shield"
        elif words_norm == "exana vita":
            return None
        else:
            group = "support"
    else:
        return None

    self_target = match_bool_prop(src, "isSelfTarget")
    need_target = (
        match_bool_prop(src, "needTarget")
        or match_bool_prop(src, "needCasterTargetOrDirection")
        or "CALLBACK_PARAM_CHAINVALUE" in src
    )
    target_mode = (
        "friend"
        if is_party_heal
        else "self"
        if self_target
        else "enemy"
        if need_target
        else "area"
    )
    spell_id_value = match_number_prop(src, "id")
    mana_value = match_number_prop(src, "mana")
    level_value = match_number_prop(src, "level")
    cooldown_value = match_number_prop(src, "cooldown")
    spell_id = spell_id_value if spell_id_value is not None else 0
    return {
        "id": words_to_id(words_norm),
        "name": name,
        "words": words_norm,
        "group": group,
        "secondaryGroup": secondary_group,
        "targetMode": target_mode,
        "area": parse_spell_area(src, target_mode),
        "manaCost": mana_value if mana_value is not None else 0,
        "minLevel": level_value if level_value is not None else 1,
        "cooldownMs": cooldown_value if cooldown_value is not None else 2000,
        "iconId": spell_id,
        "spellId": spell_id,
        "premium": match_bool_prop(src, "isPremium"),
        "vocations": parse_vocations(src),
        "sourceFile": filename,
    }


def load_otc_client_ids() -> dict[str, int]:
    if not SPELL_INFO.is_file():
        return {}
    data = json.loads(SPELL_INFO.read_text(encoding="utf-8"))
    result = {}
    for profile in (data.get("SpellInfo") or {}).values():
        for spell in profile.values():
            words = str(spell.get("words") or "").strip().lower()
            client_id = spell.get("clientId")
            if words and isinstance(client_id, (int, float)):
                result[words] = int(client_id)
    return result


def parse_all_spells() -> list[dict]:
    by_id = {}
    for directory in SPELL_DIRS:
        root = SPELLS_ROOT / directory
        if not root.is_dir():
            continue
        for path in root.iterdir():
            if path.suffix != ".lua":
                continue
            spell = parse_spell_file(path, path.read_text(encoding="utf-8"))
            if spell is not None and spell["id"] not in by_id:
                by_id[spell["id"]] = spell

    spells = sorted(by_id.values(), key=lambda spell: spell["name"])
    client_ids = load_otc_client_ids()
    for spell in spells:
        if spell["words"] in client_ids:
            spell["iconId"] = client_ids[spell["words"]]
    return spells


def potion_title(type_id: int, kind: str) -> str:
    if type_id in POTION_NAMES:
        return POTION_NAMES[type_id]
    if kind == "spirit":
        return f"Spirit Potion ({type_id})"
    if kind == "mana":
        return f"Mana Potion ({type_id})"
    return f"Health Potion ({type_id})"


def expand_base_vocations(keys: list[str]) -> list[str]:
    out = []
    for key in keys:
        for vocation in BASE_ID_TO_VOCATIONS.get(key, []):
            if vocation not in out:
                out.append(vocation)
    return out


def parse_potions_file(src: str) -> list[dict]:
    start_match = re.search(r"local\s+potions\s*=\s*\{", src)
    if not start_match:
        return []
    open_brace = src.find("{", start_match.start())
    if open_brace < 0:
        return []
    body = src[open_brace + 1 : matching_brace_end(src, open_brace)]
    out = []

    for match in re.finditer(r"\[(\d+)\]\s*=\s*\{", body):
        type_id = int(match.group(1))
        if type_id <= 0:
            continue
        entry_open = match.end() - 1
        entry = body[entry_open + 1 : matching_brace_end(body, entry_open)]
        health = re.search(r"health\s*=\s*\{\s*(\d+)\s*,\s*(\d+)\s*\}", entry)
        mana = re.search(r"mana\s*=\s*\{\s*(\d+)\s*,\s*(\d+)\s*\}", entry)
        if not health and not mana:
            continue
        level_match = re.search(r"level\s*=\s*(\d+)", entry)
        min_level = int(level_match.group(1)) if level_match else 1
        vocations = expand_base_vocations(
            re.findall(r"VOCATION\.BASE_ID\.([A-Z_]+)", entry)
        )
        kind = "spirit" if health and mana else "mana" if mana else "health"
        name = potion_title(type_id, kind)
        potion = {
            "id": potion_name_to_id(name) or f"potion_{type_id}",
            "typeId": type_id,
            "clientId": type_id,
            "name": name,
            "kind": kind,
            "minLevel": min_level,
            "vocations": vocations,
        }
        if health:
            potion["healthMin"] = int(health.group(1))
            potion["healthMax"] = int(health.group(2))
        if mana:
            potion["manaMin"] = int(mana.group(1))
            potion["manaMax"] = int(mana.group(2))
        out.append(potion)
    return sorted(out, key=lambda potion: (potion["minLevel"], potion["typeId"]))


def lua_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_voc_list(vocations: list[str]) -> str:
    if not vocations:
        return "{}"
    return "{ " + ", ".join(lua_string(vocation) for vocation in vocations) + " }"


def lua_tile_list(tiles: list[tuple[int, int]]) -> str:
    return "{ " + ", ".join(f"{{{dx}, {dy}}}" for dx, dy in tiles) + " }"


def lua_dir_map(by_dir: dict[int, list[tuple[int, int]]], indent: str = "\t\t") -> str:
    lines = [
        f"{indent}[{direction}] = {lua_tile_list(tiles)},"
        for direction, tiles in sorted(by_dir.items())
    ]
    return "{\n" + "\n".join(lines) + f"\n{indent[:-1]}}}"


def lua_area(area: dict) -> str:
    parts = [f'kind = {lua_string(area["kind"])}']
    if area.get("shape"):
        parts.append(f'shape = {lua_string(area["shape"])}')
    if "radius" in area:
        parts.append(f'radius = {int(area["radius"])}')
    if area.get("wod"):
        wod = area["wod"]
        parts.append(
            "wod = { "
            f'check = {lua_string(wod["check"])}, '
            f'name = {lua_string(wod["name"])} '
            "}"
        )
    if area.get("byDir"):
        parts.append(f"byDir = {lua_dir_map(area['byDir'])}")
    if area.get("wodByDir"):
        parts.append(f"wodByDir = {lua_dir_map(area['wodByDir'])}")
    if area.get("gradeByDir"):
        grade_lines = []
        for grade, by_dir in sorted(area["gradeByDir"].items()):
            grade_lines.append(f"\t\t[{grade}] = {lua_dir_map(by_dir, indent=chr(9)*3)},")
        parts.append("gradeByDir = {\n" + "\n".join(grade_lines) + "\n\t}")
    if area.get("tiles"):
        parts.append(f'tiles = {lua_tile_list(area["tiles"])}')
    if area.get("wodTiles"):
        parts.append(f'wodTiles = {lua_tile_list(area["wodTiles"])}')
    if "wodRadius" in area:
        parts.append(f'wodRadius = {int(area["wodRadius"])}')
    if area.get("byDir") or area.get("wodByDir") or area.get("gradeByDir"):
        return "{\n\t\t" + ",\n\t\t".join(parts) + ",\n\t}"
    return "{ " + ", ".join(parts) + " }"


def render_lua_catalog(spells: list[dict], potions: list[dict]) -> str:
    cooldown_lines = "\n".join(
        f'\t[{lua_string(spell["words"])}] = {spell["cooldownMs"]},'
        for spell in spells
    )
    allowed_words = "\n".join(
        f'\t[{lua_string(spell["words"])}] = true,' for spell in spells
    )
    words_by_id = "\n".join(
        f'\t{spell["id"]} = {lua_string(spell["words"])},' for spell in spells
    )
    voc_by_id = "\n".join(
        f'\t{spell["id"]} = {lua_voc_list(spell["vocations"])},'
        for spell in spells
    )
    min_by_id = "\n".join(
        f'\t{spell["id"]} = {spell["minLevel"]},' for spell in spells
    )
    group_by_id = "\n".join(
        f'\t{spell["id"]} = {lua_string(spell["group"])},' for spell in spells
    )
    area_by_id = "\n".join(
        f'\t{spell["id"]} = {lua_area(spell["area"])},' for spell in spells
    )
    potion_lines = []
    for potion in potions:
        parts = []
        if "healthMin" in potion:
            parts.append(f'health = {{ {potion["healthMin"]}, {potion["healthMax"]} }}')
        if "manaMin" in potion:
            parts.append(f'mana = {{ {potion["manaMin"]}, {potion["manaMax"]} }}')
        parts.append(f'minLevel = {potion["minLevel"]}')
        parts.append(f'vocations = {lua_voc_list(potion["vocations"])}')
        potion_lines.append(f'\t[{potion["typeId"]}] = {{ {", ".join(parts)} }},')

    return "\n".join(
        [
            BEGIN,
            "-- Generated by packages/asset-pipeline generate-combat-automation-catalog — do not edit.",
            "CombatAutomationConfig.SpellCooldownMsByWords = {",
            cooldown_lines,
            "}",
            "",
            "CombatAutomationConfig.AllowedSpellWords = {",
            allowed_words,
            "}",
            "",
            "CombatAutomationConfig.SpellWordsById = {",
            words_by_id,
            "}",
            "",
            "CombatAutomationConfig.SpellVocationsById = {",
            voc_by_id,
            "}",
            "",
            "CombatAutomationConfig.SpellMinLevelById = {",
            min_by_id,
            "}",
            "",
            "CombatAutomationConfig.SpellGroupById = {",
            group_by_id,
            "}",
            "",
            "CombatAutomationConfig.SpellAreaById = {",
            area_by_id,
            "}",
            "",
            "CombatAutomationConfig.PotionEffects = {",
            "\n".join(potion_lines),
            "}",
            END,
        ]
    )


def patch_lua_config(block: str) -> None:
    raw = LUA_CONFIG.read_text(encoding="utf-8")
    begin_index = raw.find(BEGIN)
    end_index = raw.find(END)
    if begin_index >= 0 and end_index > begin_index:
        patched = raw[:begin_index] + block + raw[end_index + len(END) :]
        LUA_CONFIG.write_text(patched, encoding="utf-8")
        return

    stripped = raw
    keys = (
        "SpellCooldownMsByWords",
        "PotionEffects",
        "AllowedSpellWords",
        "SpellWordsById",
        "SpellVocationsById",
        "SpellMinLevelById",
        "SpellGroupById",
        "SpellAreaById",
    )
    for key in keys:
        stripped = re.sub(
            rf"CombatAutomationConfig\.{key}\s*=\s*\{{[\s\S]*?\n\}}\n?",
            "",
            stripped,
        )
    LUA_CONFIG.write_text(stripped.rstrip() + "\n\n" + block + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    dump_json = "--dump-json" in args
    spells = parse_all_spells()
    potions = parse_potions_file(POTIONS.read_text(encoding="utf-8"))
    if dump_json:
        payload = {
            "spells": [
                {
                    "id": s["id"],
                    "words": s["words"],
                    "group": s["group"],
                    "minLevel": s["minLevel"],
                    "vocations": s["vocations"],
                }
                for s in spells
            ],
            "potions": [
                {
                    "typeId": p["typeId"],
                    "minLevel": p["minLevel"],
                    "vocations": p["vocations"],
                }
                for p in potions
            ],
        }
        print(json.dumps(payload))
        return 0
    patch_lua_config(render_lua_catalog(spells, potions))
    print(f"[combat-automation] {len(spells)} spells, {len(potions)} potions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
