#!/usr/bin/env python3
"""Haalt de actuele FPL-data en de Snoep PL-selecties op en schrijft data/players.json en data/league.json.
Draait automatisch via .github/workflows/update-data.yml. Handmatig: python3 scripts/update_data.py"""
import json, os, sys, time, urllib.request
from datetime import datetime, timezone

LEAGUE_ID = int(os.environ.get("LEAGUE_ID", "57092"))
API = "https://fantasy.premierleague.com/api"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
UA = {"User-Agent": "Mozilla/5.0 (asset-van-de-dag data updater)"}

def get(path):
    for attempt in range(4):
        try:
            req = urllib.request.Request(API + path, headers=UA)
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except Exception as e:
            if attempt == 3: raise
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

def main():
    now = datetime.now(timezone.utc)
    boot = get("/bootstrap-static/")
    events = boot["events"]
    cur = next((e for e in events if e["is_current"]), None)
    nxt = next((e for e in events if e["is_next"]), None)
    stamp = now.strftime("%Y-%m-%dT%H:%M")
    keep = [e for e in boot["elements"] if not e.get("removed")]
    players = [[e["code"], e["web_name"], (e["first_name"] + " " + e["second_name"]).strip(), e["team"], e["element_type"],
                e["now_cost"], float(e["selected_by_percent"]), e["total_points"], e["event_points"],
                e["goals_scored"], e["assists"], e["clean_sheets"], e["minutes"]] for e in keep]
    write("players.json", {
        "gw": cur["id"] if cur else 0,
        "next": {"gw": nxt["id"], "deadline": nxt["deadline_time"]} if nxt else None,
        "deadlines": [[e["id"], e["deadline_time"]] for e in events],
        "updated": stamp,
        "teams": [[t["id"], t["short_name"], t["name"]] for t in boot["teams"]],
        "players": players,
    })

    # Snoep PL: selecties van de laatste gameweek waarvan de deadline voorbij is
    passed = [e for e in events if datetime.fromisoformat(e["deadline_time"].replace("Z", "+00:00")) <= now]
    if not passed:
        print("Nog geen deadline voorbij"); return
    gw = max(e["id"] for e in passed)
    code = {e["id"]: e["code"] for e in boot["elements"]}
    entries, page = [], 1
    while True:
        st = get(f"/leagues-classic/{LEAGUE_ID}/standings/?page_standings={page}")
        entries += [r["entry"] for r in st["standings"]["results"]]
        if not st["standings"]["has_next"]: break
        page += 1
    name = st["league"]["name"]
    picks = {}
    for i, entry in enumerate(entries):
        try:
            data = get(f"/entry/{entry}/event/{gw}/picks/")
        except Exception as e:
            print("Geen picks voor", entry, e); continue
        for p in data["picks"]:
            c = code.get(p["element"])
            if c: picks.setdefault(str(c), []).append(i)
        time.sleep(0.3)
    write("league.json", {"name": name, "league": LEAGUE_ID, "gw": gw, "updated": stamp,
                          "managers": [""] * len(entries), "picks": picks})

if __name__ == "__main__":
    main()
