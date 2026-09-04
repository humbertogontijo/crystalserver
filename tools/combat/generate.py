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
LUA_CONFIG = CRYSTAL / "data-global/lib/idleot/combat_automation/01_config.lua"
SPELL_INFO = UMBRELLA / "packages/asset-pipeline/data/spellInfo.generated.json"

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


def parse_spell_area(src: str, target_mode: str) -> dict:
    if target_mode == "friend":
        return {
            "kind": "friend",
            "shape": "single",
            "radius": 0,
            "length": 0,
            "spread": 0,
        }

    need_direction = match_bool_prop(src, "needDirection")
    area_match = re.search(r"createCombatArea\(\s*(AREA[A-Z0-9_]+)", src)
    if not area_match:
        area_match = re.search(r"createCombat\(\s*(AREA[A-Z0-9_]+)", src)
    area_name = area_match.group(1) if area_match else ""
    sizes = re.findall(r"\d+", area_name)
    size = int(sizes[-1]) if sizes else 0

    if target_mode == "enemy":
        chain = re.search(r"return\s+targets\s*,\s*(\d+)\s*,", src)
        chain_range = int(chain.group(1)) if chain else None
        shape = (
            "chain"
            if chain_range is not None
            else "circle"
            if "CIRCLE" in area_name
            else "square"
            if "SQUARE" in area_name
            else "single"
        )
        radius = (
            chain_range
            if chain_range is not None
            else size
            if "CIRCLE" in area_name or "SQUARE" in area_name
            else 0
        )
        return {
            "kind": "target",
            "shape": shape,
            "radius": radius,
            "length": 0,
            "spread": 0,
        }

    if need_direction:
        length = max(1, size or 1)
        is_beam = "BEAM" in area_name
        return {
            "kind": "direction",
            "shape": "beam" if is_beam else "wave",
            "radius": 0,
            "length": length,
            "spread": 0 if is_beam else max(1, length // 2),
        }

    return {
        "kind": "self",
        "shape": (
            "circle"
            if "CIRCLE" in area_name
            else "square"
            if "SQUARE" in area_name
            else "single"
        ),
        "radius": max(0, size),
        "length": 0,
        "spread": 0,
    }


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


def matching_brace_end(src: str, open_brace: int) -> int:
    depth = 0
    for index in range(open_brace, len(src)):
        if src[index] == "{":
            depth += 1
        elif src[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    return open_brace


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
        f'\t{spell["id"]} = {{ kind = {lua_string(spell["area"]["kind"])}, '
        f'shape = {lua_string(spell["area"]["shape"])}, '
        f'radius = {spell["area"]["radius"]}, length = {spell["area"]["length"]}, '
        f'spread = {spell["area"]["spread"]} }},'
        for spell in spells
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
