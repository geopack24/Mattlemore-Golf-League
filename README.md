# Fantasy Golf League site

A one-page site, hosted free on GitHub Pages, where owners submit one golfer per tournament.

- Picks are stored in a free Supabase database (GitHub Pages alone can't remember anything).
- Before a tournament starts, everyone can see **who** has picked but not **who they picked**.
- At lock time (Thursday 7:00 AM Eastern by default) picks are revealed and frozen.
- **No mulligans:** the database refuses a golfer an owner has already used that season.
- Scoring: golfer's actual prize money × the tournament multiplier (from the league sheet).
- Owners identify with their name + a personal PIN. The commissioner has a separate PIN
  to enter weekly winnings, add owners, and edit the schedule — all from the site.

```
fantasy-golf/
├── index.html            the whole site (HTML + CSS + JS)
├── config.js             ← paste your Supabase URL + anon key here
├── supabase/schema.sql   ← run once in Supabase to create tables, rules, and the 2027 schedule
└── README.md
```

## Setup (about 15 minutes)

### 1. Create the database (Supabase)

1. Go to https://supabase.com, sign up (free), and click **New project**. Any name/region; set a
   database password and keep it somewhere safe (you won't need it for the site).
2. When the project finishes provisioning, open **SQL Editor** (left sidebar) → **New query**.
3. Open `supabase/schema.sql`, **change the commissioner PIN** on the line near the bottom that says
   `crypt('1234', ...)` to your own 4–8 digit number, paste the whole file into the editor and click **Run**.
   You should see "Success. No rows returned."
4. Add your owners. In the same SQL editor run one line per owner (name, PIN):
   ```sql
   select admin_set_owner('YOUR-COMMISSIONER-PIN', 'GP',   '4821');
   select admin_set_owner('YOUR-COMMISSIONER-PIN', 'Mike', '7710');
   ```
   (You can also do this later from the site's **Commissioner** tab.)
5. Go to **Project Settings → API** and copy two values: **Project URL** and the **anon public** key.

### 2. Connect the site

Open `config.js` and paste the two values:

```js
window.LEAGUE_CONFIG = {
  SUPABASE_URL: "https://abcdefgh.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOi...",
  LEAGUE_NAME: "Fantasy Golf 2027",
};
```

The anon key is meant to be public. Nobody can read or change the tables directly with it —
the only things it can do are call the PIN-protected functions in `schema.sql`.

### 3. Publish on GitHub Pages

1. On GitHub click **New repository**, name it e.g. `fantasy-golf`, Public, then **Create**.
2. Click **uploading an existing file**, drag in `index.html`, `config.js`, `README.md` and the
   `supabase` folder, then **Commit changes**.
3. Go to **Settings → Pages**. Under *Build and deployment* choose **Deploy from a branch**,
   branch `main`, folder `/ (root)`, **Save**.
4. After a minute the page shows your URL: `https://<your-username>.github.io/fantasy-golf/`.
   Send that link to the league.

## Running the league each week

**Owners:** open the site, pick the tournament (it defaults to the next one), choose your name,
enter your PIN and a golfer, click **Lock it in**. The form shows the golfers you've already burned.
You can change your pick until lock time. **My Picks** shows your full season.

**Commissioner (after each tournament):** Commissioner tab → enter your PIN → choose the tournament →
**Load picks** → type each golfer's prize money → **Save**. Standings update instantly.
If someone forgets their PIN, re-save them under **Owners** with a new PIN.

## The 2027 schedule

`schema.sql` seeds the 29 league events for 2027 (WM Phoenix Open, Feb 11 → TOUR Championship, Aug 26),
picked the same way as the 2026 sheet: no opposite-field events, no January West Coast swing. Multipliers
carry over — majors 3×, PLAYERS and FedEx St. Jude 1.5×, Zurich and BMW 2×, TOUR Championship 1.35×.
The Zurich Classic (two-man teams) is scored like any other week: pick one golfer, his listed prize money counts.

Two things to know:
- **Purses are last year's numbers** until the Tour publishes 2027 figures. They only show on the board;
  scoring always uses the winnings you enter. Fix any of them under Commissioner → Schedule.
- If the league wants Pebble Beach (Feb 4, Signature Event) or any other week, add it the same way.

## Next season

Commissioner tab → **Schedule**: add each tournament with its start date, lock time, purse and multiplier
(or paste a new block of `insert into tournaments ...` rows in the SQL editor, copying the 2027 block in
`schema.sql`). Then set **Current season** to the new year. Used-golfer history resets per season.

## Changing the lock time

The default lock is Thursday 7:00 AM Eastern (first tee times). Edit any tournament's **Lock** in the
Commissioner tab, or change the `07:00` values in `schema.sql` before running it.

## Notes

- Picks are hidden from *everyone* before lock, including the commissioner, when viewed through the site.
  (The project owner can always see raw rows in the Supabase dashboard — that's just you.)
- Golfer names are matched case- and space-insensitively, so "scottie scheffler" and
  "Scottie Scheffler" count as the same golfer. Owners should use full names.
- The golfer autocomplete only grows with names from tournaments that have already locked, so an
  unusual pick can't be spotted in the dropdown before lock.
- Supabase free tier pauses a project after a week of no traffic; opening the site (or the Supabase
  dashboard) wakes it up. During the season it won't be idle.
