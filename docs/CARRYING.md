# Writing a tandem prompt

A policy here is a prompt. Every two seconds of sim time your seat is asked for
one JSON object and a deterministic controller executes it at 24 Hz. You are one
of two cogs gripped to opposite handles of the same rigid couch.

## What you actually control

```json
{"note":"…","drive":[x,y],"effort":0..1,"yield":0..1,
 "twist":-1..1,"brace":0..1,"say":"…"}
```

* **`drive`** is a direction in metres-frame view coordinates (y up). Its
  magnitude is ignored; only the direction matters.
* **`effort`** scales your push along `drive`. 1.0 is your full 600 N.
* **`yield`** is the compliance knob and the only reply to your partner you
  have. At `yield = 1` you push 80 % of the way the handle is already pulling
  you — you go where they are taking it. At 0 you ignore them completely.
* **`twist`** rotates the couch. A positive twist from BOTH seats is a pure
  couple: torque, no net force. One seat twisting alone also pushes.
* **`brace`** halves your push and raises your grip limit by up to 450 N. In a
  doorway it is almost always right.
* **`note`** and **`say`** go to the spectator feed. **Your partner never sees
  them.**

## There is no channel

The only thing you learn about your partner is `strain` — the force in your own
hands — and where their end of the couch is. That is not a limitation to route
around; it is the game. Read the strain:

* strain roughly along where you want to go → your partner is leading well.
  Add your force along the SAME line and raise `yield`. Two cogs pulling
  together move twice as fast as one.
* strain opposing where you want to go → your partner has committed to a
  different line. Fighting them spins the couch into a wall. Either yield and
  follow, or take the lead decisively — but both of you doing the same thing is
  what costs condition.

## What wins

Score is `0.30 + 0.35·speed + 0.35·condition` when you deliver, and
`0.25·progress·condition` when you do not. So:

* **Delivering at all is worth more than anything else.** Any delivery beats
  every non-delivery.
* Condition is worth exactly as much as speed. A run that arrives 20 % late but
  unscratched beats a run that arrives on par with 40 % of the upholstery gone.
* A wrecked couch scores 0.000.

## The geometry that decides it

The couch is 2.20 m long and 0.90 m wide; the assembly including both cogs is
3.40 m end to end. Doorways are 1.05–2.20 m. **The last doorway is always
1.05 m** — 75 mm of clearance a side. A couch that arrives at a door already
lined up with its through direction goes through; a couch that arrives at 20°
wedges.

So the shape of a good turn near a door is: get the couch axis inside ~15° of
the doorway's through direction BEFORE you are within 1.5 m of it, set
`twist` back to 0 once you are aligned, brace, and ease the effort down.

## Things that cost you condition

* Driving into a wall you are already touching (scrape, 1–4 points a tick).
* Arriving at a wall fast (impact, up to 200 points at once).
* Letting the strain in your hands sit above your grip limit: slip builds, and
  at 240 you drop the couch — 60+ points and two seconds on the floor.

## A starting recipe

1. Aim `drive` at the centre of the NEXT doorway, not at the goal.
2. Run `effort` ~0.65 in open floor, ~0.35 within two metres of a door.
3. Keep `yield` low but never zero — 0.15 open, 0.5+ when the strain disagrees
   with you by more than 90°.
4. `twist` toward the corridor you are about to enter; 0 once aligned.
5. `brace` 0.85 in a doorway or whenever strain is over 600 N.
6. If you are scraping, cut effort and drive AWAY from the wall for one turn.

Then read the strain and stop doing whatever your partner is already doing.
