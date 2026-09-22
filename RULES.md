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

## Tees *(Sep 22 2026)*
14. Every owner has **3 tees per tournament**. Each card costs **0 to 3 tees** to play (printed as tee pips on the type
    bar; 0 = free). The tees a card costs are spent for that tournament when it is played; Instants and responses
    cost tees like any other card. Taking a card back before lock refunds its tees.

## Booster packs *(Sep 22 2026)*
15. At the end of every tournament (midnight ET after day 4) **every owner receives one booster pack of 5 cards**,
    drawn at random from the card library. Pack cards go straight into the owner's hand.
16. Pack odds by slot: cards 1–3 are Common 80% / Rare 20%; card 4 is Common 50% / Rare 40% / Legendary 10%;
    card 5 is guaranteed Rare or better: Rare 70% / Legendary 25% / Mythic 5%. If the library has no card of the
    rolled tier, the next tier down is used. The same design can appear more than once.
17. Pack pulls are announced on Discord by rarity only (the cards themselves stay secret until played).

## Copy limits *(Sep 22 2026)*
18. A card design may carry a **maximum number of copies in circulation** (copies currently in owners' hands). Once that
    many are held, the design is not dealt again — by the commissioner or by booster packs — until a copy is played.
    **The Fellowship of the Swing is capped at 2.** Other designs are unlimited unless the commissioner sets a cap.
