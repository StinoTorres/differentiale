#!/usr/bin/env python3
"""Haalt de FPL-data en de Snoep PL-selecties op, steeds van de laatst afgeronde gameweek.

- schrijft data/players.json (zoeken in de app en de oefenronde) en data/league.json (oefenronde)
- zet dezelfde gegevens in Supabase (av_admin_load), waar het echte spel mee rekent

Draait automatisch via .github/workflows/update-data.yml. Handmatig: python3 scripts/update_data.py
Voor Supabase zijn de omgevingsvariabelen SUPABASE_URL en SUPABASE_SERVICE_ROLE_KEY nodig."""
import json, os, time, urllib.request
from datetime import datetime, timezone

LEAGUE_ID = int(os.environ.get("LEAGUE_ID", "57092"))
API = "https://fantasy.premierleague.com/api"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
UA = {"User-Agent": "Mozilla/5.0 (differentiale data updater)"}


def get(path):
    for attempt in range(4):
        try:
            req = urllib.request.Request(API + path, headers=UA)
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except Exception:
            if attempt == 3:
                raise
            time.sleep(3 * (attempt + 1))


def write(name, obj):
    path = os.path.join(ROOT, "data", name)
    new = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    old = open(path).read() if os.path.exists(path) else None
    if old is not None:
        a, b = json.loads(old), json.loads(new)
        a.pop("updated", None); b.pop("updated", None)
        if a == b:
            print(name, "ongewijzigd"); return
    open(path, "w").write(new); print(name, "bijgewerkt")


PL_API = "https://footballapi.pulselive.com/football"
PL_HDR = {"User-Agent": UA["User-Agent"], "Origin": "https://www.premierleague.com", "Referer": "https://www.premierleague.com/"}


def pl_get(path):
    for attempt in range(3):
        try:
            req = urllib.request.Request(PL_API + path, headers=PL_HDR)
            with urllib.request.urlopen(req, timeout=40) as r:
                return json.load(r)
        except Exception:
            if attempt == 2:
                raise
            time.sleep(3)


def shirt_numbers():
    """Rugnummers per FPL-spelerscode, uit de officiele Premier League-databron (Opta-id = FPL-code)."""
    nums = {}
    try:
        cs = pl_get("/competitions/1/compseasons?page=0&pageSize=1")["content"][0]["id"]
        cs = int(cs)
        for t in pl_get(f"/compseasons/{cs}/teams"):
            try:
                staff = pl_get(f"/teams/{int(t['id'])}/compseasons/{cs}/staff?altIds=true&type=player")
            except Exception as e:
                print("Geen selectie voor", t.get("name"), e); continue
            for pl in staff.get("players", []):
                opta = (pl.get("altIds") or {}).get("opta", "")
                num = (pl.get("info") or {}).get("shirtNum")
                if opta.startswith("p") and num is not None:
                    nums[int(opta[1:])] = int(num)
            time.sleep(0.3)
    except Exception as e:
        print("Rugnummers niet beschikbaar:", e)
    print("Rugnummers gevonden:", len(nums))
    return nums


def supabase_rpc(fn, payload):
    url = os.environ.get("SUPABASE_URL", "").rstrip("/")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not url or not key:
        print("Geen SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY: Supabase overgeslagen"); return None
    req = urllib.request.Request(f"{url}/rest/v1/rpc/{fn}", data=json.dumps(payload).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "apikey": key, "Authorization": "Bearer " + key})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def live_points(gw):
    """Punten per FPL-element in gameweek gw (uit /event/{gw}/live/)."""
    return {el["id"]: el["stats"]["total_points"] for el in get(f"/event/{gw}/live/")["elements"]}


def main():
    """Rekent altijd vanaf de laatst afgeronde gameweek.

    Een gameweek telt als afgerond zodra FPL hem op finished en data_checked zet (de bonuspunten
    zijn dan definitief). Loopt er al een nieuwe gameweek, dan worden de punten van die lopende
    gameweek van de seizoenspunten afgetrokken, zodat de cijfers precies 'na GW N' zijn.
    Er wordt pas iets bijgewerkt als er een nieuwere afgeronde gameweek is dan in data/players.json
    staat (of met FORCE=1)."""
    now = datetime.now(timezone.utc)
    stamp = now.strftime("%Y-%m-%dT%H:%M")
    boot = get("/bootstrap-static/")
    events = boot["events"]
    done = [e for e in events if e.get("finished") and e.get("data_checked")]
    if not done:
        print("Nog geen afgeronde gameweek"); return
    lgw = max(e["id"] for e in done)
    old_path = os.path.join(ROOT, "data", "players.json")
    old_gw = json.load(open(old_path)).get("gw", 0) if os.path.exists(old_path) else 0
    force = os.environ.get("FORCE", "") in ("1", "true", "yes")
    if lgw <= old_gw and not force:
        print(f"Laatst afgeronde gameweek is GW{lgw}, data staat al op GW{old_gw}: niets te doen"); return
    print(f"Bijwerken naar de stand na GW{lgw} (was GW{old_gw})")

    cur = next((e for e in events if e["is_current"]), None)
    nxt = next((e for e in events if e["id"] == lgw + 1), None)
    gw_pts = live_points(lgw)
    # punten van gameweeks na lgw die al lopen, tellen nog niet mee
    later = {}
    if cur and cur["id"] > lgw:
        for g in range(lgw + 1, cur["id"] + 1):
            for k, v in live_points(g).items():
                later[k] = later.get(k, 0) + v
        print(f"Punten van GW{lgw + 1}-GW{cur['id']} (nog bezig) afgetrokken")

    keep = [e for e in boot["elements"] if not e.get("removed")]
    nums = shirt_numbers()
    players = [[e["code"], e["web_name"], (e["first_name"] + " " + e["second_name"]).strip(), e["team"], e["element_type"],
                e["now_cost"], float(e["selected_by_percent"]), e["total_points"] - later.get(e["id"], 0), gw_pts.get(e["id"], 0),
                e["goals_scored"], e["assists"], e["clean_sheets"], e["minutes"],
                e.get("squad_number") or nums.get(e["code"])] for e in keep]
    write("players.json", {
        "gw": lgw,
        "next": {"gw": nxt["id"], "deadline": nxt["deadline_time"]} if nxt else None,
        "deadlines": [[e["id"], e["deadline_time"]] for e in events],
        "updated": stamp,
        "teams": [[t["id"], t["short_name"], t["name"]] for t in boot["teams"]],
        "players": players,
    })
    fpl = [[p[0], p[1], p[3], p[4], p[5], p[6], p[7], p[8]] for p in players]  # code, web, team, pos, price, own, pts, gw
    meta = {"fpl_gw": lgw}
    counts = None

    # Snoep PL: selecties van diezelfde afgeronde gameweek
    code = {e["id"]: e["code"] for e in boot["elements"]}
    entries, page = [], 1
    while True:
        st = get(f"/leagues-classic/{LEAGUE_ID}/standings/?page_standings={page}")
        entries += [r["entry"] for r in st["standings"]["results"]]
        if not st["standings"]["has_next"]:
            break
        page += 1
    picks = {}
    for i, entry in enumerate(entries):
        try:
            data = get(f"/entry/{entry}/event/{lgw}/picks/")
        except Exception as e:
            print("Geen picks voor", entry, e); continue
        for p in data["picks"]:
            c = code.get(p["element"])
            if c:
                picks.setdefault(str(c), []).append(i)
        time.sleep(0.3)
    write("league.json", {"name": st["league"]["name"], "league": LEAGUE_ID, "gw": lgw, "updated": stamp,
                          "managers": [""] * len(entries), "picks": picks})
    counts = {k: len(set(v)) for k, v in picks.items()}
    meta.update({"league_name": st["league"]["name"], "league_total": len(entries), "league_gw": lgw})

    res = supabase_rpc("av_admin_load", {"p_fpl": fpl, "p_picks": counts, "p_meta": meta})
    if res is not None:
        print("Supabase:", res)


if __name__ == "__main__":
    main()
