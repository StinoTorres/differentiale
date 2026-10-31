#!/usr/bin/env python3
"""Haalt de actuele FPL-data en de Snoep PL-selecties op.

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


def supabase_rpc(fn, payload):
    url = os.environ.get("SUPABASE_URL", "").rstrip("/")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not url or not key:
        print("Geen SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY: Supabase overgeslagen"); return None
    req = urllib.request.Request(f"{url}/rest/v1/rpc/{fn}", data=json.dumps(payload).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "apikey": key, "Authorization": "Bearer " + key})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def main():
    now = datetime.now(timezone.utc)
    stamp = now.strftime("%Y-%m-%dT%H:%M")
    boot = get("/bootstrap-static/")
    events = boot["events"]
    cur = next((e for e in events if e["is_current"]), None)
    nxt = next((e for e in events if e["is_next"]), None)
    keep = [e for e in boot["elements"] if not e.get("removed")]
    players = [[e["code"], e["web_name"], (e["first_name"] + " " + e["second_name"]).strip(), e["team"], e["element_type"],
                e["now_cost"], float(e["selected_by_percent"]), e["total_points"], e["event_points"],
                e["goals_scored"], e["assists"], e["clean_sheets"], e["minutes"]] for e in keep]
    gw = cur["id"] if cur else 0
    write("players.json", {
        "gw": gw,
        "next": {"gw": nxt["id"], "deadline": nxt["deadline_time"]} if nxt else None,
        "deadlines": [[e["id"], e["deadline_time"]] for e in events],
        "updated": stamp,
        "teams": [[t["id"], t["short_name"], t["name"]] for t in boot["teams"]],
        "players": players,
    })
    fpl = [[p[0], p[1], p[3], p[4], p[5], p[6], p[7], p[8]] for p in players]  # code, web, team, pos, price, own, pts, gw
    meta = {"fpl_gw": gw}
    counts = None

    # Snoep PL: selecties van de laatste gameweek waarvan de deadline voorbij is
    passed = [e for e in events if datetime.fromisoformat(e["deadline_time"].replace("Z", "+00:00")) <= now]
    if passed:
        lgw = max(e["id"] for e in passed)
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
