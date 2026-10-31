# Differentiale

Dagelijkse FPL-raadpuzzel voor Snoep PL: raad de geheime FPL-asset in zes pogingen op club, positie, prijs, eigendom, seizoenspunten en punten van de laatste gameweek. Met klassement (vandaag, week, seizoen), weekbekers, poules voor vrienden, een herstelcode en een Snoep PL-hint. Elke dag een andere speler uit 240 bekende assets, zonder herhalingen dit seizoen; raden kan met alle FPL-spelers.

Spelen: https://stinotorres.github.io/differentiale/

## Hoe het werkt
- **Pagina:** `index.html` op GitHub Pages, installeerbaar als app (`manifest.webmanifest`, `sw.js`).
- **Server:** Supabase. Het antwoord van de dag, de scores, de hint, het klassement, de poules en de herstelcodes zitten daar, achter functies (`supabase/schema.sql`). De tabellen zijn niet leesbaar met de publieke sleutel, dus valsspelen via de paginacode kan niet.
- **FPL-data:** `scripts/update_data.py` haalt FPL-data en de Snoep PL-selecties (league 57092) op, werkt `data/*.json` bij en stuurt alles naar Supabase. Het spel rekent altijd met de stand na de **laatst afgeronde gameweek** (FPL `finished` + `data_checked`): seizoenspunten zonder de punten van een lopende gameweek, GW-punten van die afgeronde gameweek, en de Snoep PL-teams van diezelfde gameweek. De Action kijkt elke 3 uur of er een nieuwe gameweek is afgerond en doet anders niets. Met de hand: Actions → FPL-data bijwerken → Run workflow (vink *force* aan om toch te verversen).

## Instellen (eenmalig)
1. ~~**Supabase:** `supabase/schema.sql` en `supabase/seed.sql` draaien~~ — gedaan op 31-10-2026 in het Transferroute-project (`lqsltyccaavymdivkoex`); alles heet `av_…`. Daarna ook `kleine-speler.sql` en `gisteren.sql`.
2. ~~**config.js:** Project URL en publishable key~~ — ingevuld.
3. **GitHub Pages:** Settings → Pages → Deploy from a branch → `main` / root.
4. **Automatische update:** Settings → Secrets and variables → Actions → voeg `SUPABASE_URL` en `SUPABASE_SERVICE_ROLE_KEY` toe (service_role key, Project Settings → API). Deze sleutel is geheim: alleen als GitHub-secret, nooit in een bestand.
