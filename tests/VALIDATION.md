# Split-screen validation

The November 10 update was checked with copied saves, stock OBSE64 and two
simulated controllers. The package installer deployed onto a test installation
without the previous mod files. The original installation was restored after
each run.

Verified in game:

- A cold restart restored Player 2 inside the hotel while Player 1 remained
  outside. The same actor, 48 inventory stacks, item counts and equipped items
  were retained. The release capability path was tested with experimental
  travel disabled.
- Player 2 entered and left the hotel without moving Player 1. When Player 1
  occupied the normal landing point, a collision-checked alternative was used.
- Player 2's 30-second countdown respawned them from the hotel beside Player 1,
  preserving their inventory and equipped gear.
- The same recovery completed with the controller session disconnected, and
  inventory counts and equipped flags still matched after reconnecting.
- Player 1's countdown completed without opening the stock death menu.
  Nearby NPCs continued moving after recovery.
- Player 2 displayed a voiced response in the stock dialogue pane, using
  topics selected from the campaign's known topics.
- Map marker bearings and distances followed Player 2's own position.
- Weapon condition values appeared in Player 2's inventory.
- Walking and running kept Player 2's eye height near 75–78 Unreal units above
  the capsule origin. An attack state was observed. The movement comparison
  was obstructed by nearby characters and walls, so it does not establish
  complete movement or animation parity.

The cell-reference cleanup crash was traced to an invalid reference during
shutdown after an experimental transfer. Transfers now use the engine's full
cell-change path. Repeated shutdowns completed without that crash. This is
repeat-test evidence, not a guarantee against other crashes.

The automated regression suite covers save identity, equipment verification,
recovery retries, collision-checked landings, independent compass snapshots,
and dialogue catalogs larger than the backend's bounded response cache.

Still unfinished: arbitrary independent loading-door travel and distant native
world simulation, complete quest effects and services, independently resolved
quest/custom compass markers, calculated inventory damage and armor ratings,
and full first-person animation parity. General travel stays experimental.
