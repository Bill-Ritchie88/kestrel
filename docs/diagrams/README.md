# Kestrel diagrams (November 2026)

Each diagram has its Mermaid source (`.mmd`), a PNG for the report and an SVG. To regenerate one: `mmdc -i name.mmd -o name.png -s 2 -b white`.

| File | Suggested caption |
|---|---|
| architecture | Figure X: Kestrel system architecture. The assistant proposes actions; the REST tier and the database enforce them. |
| deployment | Figure X: Kestrel deployment on Cloudflare Pages, Render and Supabase (free tiers). |
| erd | Figure X: Kestrel entity relationship diagram (migrations 000 to 013; 013 changes only the rebooking procedure, so no table changed). |
| sequence-rebooking | Figure X: Sequence of a passenger rebooking (UC4), including the refusal path. Drawn before seat selection (FR-16): the seat-map step and the 409 `SEAT_TAKEN` path are not shown yet. |
