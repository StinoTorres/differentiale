# Asset van de Dag

Dagelijkse FPL-raadpuzzel voor Snoep PL: raad de geheime FPL-asset in zes pogingen op club, positie, prijs, eigendom, seizoenspunten en punten van de laatste gameweek. Met klassement (vandaag, week, seizoen) en een Snoep PL-hint.

Spelen: https://stinotorres.github.io/asset-van-de-dag/

## Hoe het werkt
- **Pagina:** `index.html`, gehost met GitHub Pages.
- **Klassement:** Supabase (tabel `players`, zie `supabase/schema.sql`). Spelers loggen automatisch anoniem in, een account is niet nodig.
- **FPL-data:** `.github/workflows/update-data.yml` draait elke 3 uur `scripts/update_data.py`. Dat script werkt `data/players.json` en de Snoep PL-selecties in `data/league.json` (league 57092) bij.

## Instellen
1. Supabase: maak een project, plak `supabase/schema.sql` in de SQL Editor en zet onder Authentication > Sign In / Providers **Allow anonymous sign-ins** aan.
2. Vul `config.js` met de Project URL en de anon/publishable key.
3. GitHub: Settings > Pages > Deploy from a branch > `main` / root.
