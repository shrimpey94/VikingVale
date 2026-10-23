# Soul / Worship System — design

_Design capture 2026-09-19. The **Soul** skill's sink. Future update (not 1.7.0). Replaces
the placeholder "prayer" idea with a Norse worship system so it isn't a RuneScape clone._

## Concept
You **worship the Old Gods** via **blót** (offerings). You **offer the buried remains you
gather** (Bone Fragment / Cursed Bone / Soul Essence — the ~50% monster drops) at a god's
**shrine** → trains **Soul** and banks that god's **boon**. Boons are **situational, timed
buffs** you choose and activate — not a persistent stat bar.

### How it differs from RS prayer (on purpose)
- **Not one generic bar** — you pick a **god** and get *that god's* themed boon.
- **The sink closes the Soul loop** — the remains you gather ARE the offering.
- **Boons are carried & activated** (timed, situational), not an always-on drain.
- Framing is Norse worship + tied to the world's factions/lore, not a copied mechanic.

## Mechanics (owner spec, 2026-09-19)
- **Hold ONE boon type at a time.** You're devoted to one god's boon; offering at a
  *different* god's shrine **switches** your held type (unspent charges of the old are
  lost — devotion is a commitment).
- **Charges stack up to your Soul level.** Soul 40 → bank up to 40 charges. This gives the
  Soul skill a clear meaning: a bigger reserve. Offering remains adds charges (trains Soul).
- **Activate for a TIMED buff. Buffs do NOT stack** — activating one replaces/refreshes any
  active buff (only one boon effect at a time).
- Offering + activating happen at / after visiting a **shrine** (see placement).

## The 7 gods
The 5 "old gods" can seed the human towns; the **2 faction gods gate behind the new villages**
(reach + be civil with them to worship) — ties Soul → factions → exploration.

| God | Boon (working) | Effect (tune later) | Shrine home |
|---|---|---|---|
| **Odin** | Insight | +XP gain (or +rare-find) for a duration | a human town / Helheim |
| **Thor** | Wrath | +combat damage / crit | a human town |
| **Freyja** | Bounty | +gathering / farming yield | a human town |
| **Njörd** | Tides | +fishing / sailing (catch rate, boat speed, fewer sea-monsters) | Bjorn's Landing (harbor) |
| **Ancestors** | Ward | survive-death-once (get up at partial HP) — or damage resist | a temple / hall |
| **Dragon God** 🆕 | Dragonfire | burst damage + fire resistance (aggressive) | **Dragon Village** |
| **Troll God** 🆕 | Vigor | HP regen / damage-taken reduction (trolls regenerate — tanky) | **Troll Town** |

- **Placement:** each shrine sits **in / near its town, or inside a church/temple** if that
  town has one. Dragon/Troll shrines live in their villages, so those boons come **with the
  villages content update**; the 5 old-god shrines can ship earlier.

## Loop
gather remains (Soul drops) → **offer at a god's shrine** (trains Soul + banks that god's
boon, up to Soul level) → **activate** a charge for a timed, non-stacking buff → repeat /
switch gods when you want a different edge.

## Reputation gating — the unified loop (owner spec, 2026-09-20)
Soul-worship IS the town/faction reputation loop — one system for all 7 towns/villages.
- **Worship at a town's altar** (offer remains / train Soul there) **raises your REP** with
  that town/village. Its **quests** and honest **trade** also raise it. Hostile acts (attacking
  its people/kin) **lower** it. Uses the existing rep core (`_rep_add`).
- **Boons unlock at a rep threshold** — you can't collect a town's god-boon until you've
  earned enough standing there. Non-human villages start **low/hostile** (earn from the
  bottom — "civil if you're civil"); human towns start neutral.
- **Once unlocked, each altar use grants a boon charge** — up to your **Soul level** (per the
  charge cap above).
- **Rep tier → town bonuses / penalties:** good standing = perks (better prices, services,
  guard help, boon access); bad standing = penalties (hostile guards, gouged prices, barred
  boons/services).
- So: **Soul + Reputation + the "civil if you're civil" factions are one loop** — worship a
  town's god → earn its standing → unlock + collect its boon → enjoy its town perks (or suffer
  the opposite if you've wronged them).

## To decide before building
- Exact buff effects + magnitudes + durations per god (balance).
- Does switching gods **lose** unspent charges (spec says yes) or convert a fraction?
- Charge cost per activation (1 charge = 1 buff? or scaled?).
- Do shrines need to be *unlocked* (Dragon/Troll via faction rep)?
- Client UI: the "boonbar" (held god + charge count + activate button) + shrine interaction.
- Lore hooks: which gods, which grudges (feeds the lore bible + the faction villages).

> Depends on: the **2 faction villages** (Dragon/Troll shrines) and the **lore bible**
> (who the gods are). The 5 old-god shrines + the core offer/activate loop can be built
> independently once the Soul remains have somewhere to go.
