# Mattlemore Golf League — card rules ledger

The commissioner's rulings, in the order they were made. Every rule here is enforced by the site
(`supabase/schema.sql`) unless marked *manual*. This file will become the Rules page on the site.

## Picks
1. One golfer per owner per tournament. Picks can be changed until lock (Thursday 7:00 AM ET by default).
2. **No mulligans:** a golfer may be used once per season per owner (a Mulligan card lifts this for one week).
3. Score = the golfer's actual prize money × the tournament multiplier.

## Cards — general
4. Cards are dealt by the commissioner. Only the owner sees their hand.
5. Non-Instant cards must be played **before lock**. They are revealed at lock, along with the picks.
6. **Limit: no owner may play more than 3 cards in a single tournament**, unless the card text specifically
   exempts that card from the limit. *(Sep 17 2026.)* The commissioner marks such cards "exempt from the
   3-card limit" in the designer; exempt cards don't count toward the three.
7. Shields cancel duels, steals, swaps, curses and stroke adjustments aimed at their holder.

## Instants *(Sep 17 2026)*
8. A card whose type line says **Instant** may be played **mid-tournament, after lock**.
9. Instants must be played **before 8:00 PM ET on day 3** of the tournament (Saturday for a Thursday start).
10. **Response:** an owner who has had an Instant played against them may respond with their own Instant at any
    time **before the end of the tournament** (midnight ET after day 4).
11. If the response is played **on the final day** (day 4), it may only target owners who have already targeted
    that owner with an Instant in this tournament. Before the final day a response may target anyone.
12. Cards played mid-tournament are public immediately (This Week → Cards in play) and are announced on Discord.

## Stroke adjustments *(Sep 17 2026)*
13. A stroke-adjustment card adds (+N) or removes (−N) strokes from the target owner's golfer. It is applied
    automatically on the live leaderboard: the adjusted score is re-ranked against the real field and the
    owner is paid what that finish earns.
