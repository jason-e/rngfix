## Tick Simulation

This is a simple overview of some key engine steps for reference. Not all of these are used by RNGFix, nor is this all-inclusive.

1. **`OnPlayerRunCmd`** (SourceMod's public forward) - This function should really only be used for modifying player inputs. If you need to run some code for each client for each command that is actually executed (i.e. where the server is not overloaded), you should probably use a PreThink or PreThinkPost hook. In many cases doing stuff here (or in OnPlayerRunCmdPost) is fine as long as you are aware that this does not have a 1:1 relationship with physically simulated client ticks.

    (Note that if the server is overloaded, the command is dropped and the following steps are skipped)

    1. **`PreThink/PreThinkPost`** - This is a convenient function to hook that is run right before the command is processed and the player is moved, triggers are touched, etc.
    2. **`CGameMovement::ProcessMovement`** - This is where the key and mouse data for this user command are applied and the player is moved one tick
    3. **`CGameMovement::ProcessImpacts`** - This is where triggers are actually "touched", note that this is enitrely after movement for this tick has completed
    4. **`PostThink/PostThinkPost`** - This is a convenient function to hook that is run right after the command is processed and the player is moved, triggers are touched, etc.


2. **`OnPlayerRunCmdPost`** - This should most correctly be used as a convenient way to check the final inputs for this command after all plugins have potentially modified them. This forward is fired even if the command was actually dropped.



## Technical Overview of Fixes

These fixes are split into two groups: pre-tick fixes -- which are detected and applied immediately *before* a user command is run and a tick is simulated -- and post-tick fixes, which correct the results of a tick immediately *after* it is simulated. This just depends on what I decided was the best way to apply these fixes.

The actions of this plugin are coupled fairly tightly to the engine's movement processing (the most important parts are executed immediately before `CGameMovement::ProcessMovement` is run, the rest happens before each player's `PostThink`) and thus this plugin is unlikely to interfere with other plugins, or be negatively impacted by them. To put it another way, it is safe for other plugins to do whatever they want in `OnPlayerRunCmd/OnPlayerRunCmdPost` and player `PreThink` calls without interfering with these fixes.

In order to understand some of these problems and their fixes, it is relevant to know that the engine will only consider a player "on the ground", and thus able to walk and jump, if their Z velocity is less than positive 140.0. If this is not the case, surfaces that are otherwise shallow enough to walk on will essentially behave like surf ramps because the player is considered in the air rather than standing on them. This is why the player is not able to rapidly bhop up steep inclines when moving faster than a certain speed.

---


**Downhill Inclines** [Post-tick]

If the plugin detects that the player just landed on the ground, but did so without ever colliding with it this tick, the player's velocity is updated to reflect what it would have been had the player actually collided with it. This fix is only applied if a collision would result in the player having a larger absolute amount of horizontal speed than before, which is always the case when falling straight down or moving "downhill", and is *sometimes* the case when moving uphill, especially for steep inclines. This is the same criteria that the original slopefix used to determine when to apply the fix.

The reason it is possible to "land" on the ground without actually touching it is because the engine will consider a player "on the ground" if there is walkable ground *within 2 units* below them at certain times within the simulation of a tick. If it just so happens that you end up within 2 units of a walkable surface at the end of a tick, the engine effectively considers you to have landed on it, which zeroes out your Z velocity immediately with no consideration for the interaction between that Z velocity and the angle of the ground. This issue is more prevalent on **higher** tickrates.

The original slopefix plugin handled this fix slightly differently. Its deflection velocity calculation does not take basevelocity into effect, and more importantly: when the new velocity is applied, any existing basevelocity is baked into the player's velocity immediately, which unfortunately results in a "double boost" if the player jumps on an incline while touching a `trigger_push`. RNGFix handles these things more accurately which eliminates this side-effect, but if you *really* want the old behavior (double boosts) for legacy reasons, set `rngfix_useoldslopefixlogic` to `1` on a case-by-case, per-map basis.

---
**Uphill Inclines** [Pre-tick]

This fix is very much the opposite of the downhill incline fix and aims to guarantee the result that is the opposite of what the downhill incline fix does. Occurrences of this issue are more prevalent on **lower** tickrates.

If the plugin detects that the player *will* collide with an incline (in an "uphill" direction, or into the incline) once this tick is simulated, and it is possible to land on this surface (that is, the surface is not too steep to walk on, and the player's Z velocity at the time of collision is less than positive 140.0), then the player is moved *away* from the incline such that they will barely not collide with the incline by the end of the tick. Note that this adjustment is often only a few units or less and is totally imperceptible to the player in real-time.

This change means that instead of colliding and deflecting along the incline, the player will instead land on the incline without colliding with it. This is desirable because landing immediately zeroes out Z velocity, and the player is able to jump while having the full horizontal velocity they started with. In the event of going up a moderately steep incline, this results in the most favorable possible collision with the surface on the following tick and the greatest possible amount of retained speed when "launching" off the incline.

Note that this fix will not be applied if the downhill fix is enabled *and* that fix would result in horizontal speed gain as explained above.

This plugin also gives you the option of normalizing the random behavior of jumping uphill in the opposite way, such that doing so always results in a *collision* with the surface -- and thus a loss of speed. This setting is not recommended, as jumping up even the slightest of inclines can quickly sap player speed, while doing so without the plugin would almost never result in lost speed. To enable this, set `rngfix_uphill` to `-1`. This effectively makes the uphill incline fix function identically to the downhill incline fix, except it is executed even when moving uphill and when doing so results in horizontal speed loss.

---
**Edge Bugs** [Pre-tick]

The upcoming tick is simulated to determine if the following are true:
1. The player will collide with a walkable surface -- This is important because the general possibility of being able to land/jump but not actually doing so is what defines this bug
2. After colliding, the player's Z velocity is less than positive 140.0 (a requirement to be able to land, and thus jump rather than slide)
3. Once the *remainder* of the tick is simulated following the collision, the player ends up in a location where there is no ground to land on below them

If all of these are true, the player's position is adjusted such that they will barely avoid colliding with the ground by the end of the tick. This is effectively the same solution as the uphill incline fix, but with different activating conditions. Occurrences of this issue are more prevalent on **lower** tickrates.

---
**Trigger Jumping** [Post-tick]

If the plugin detects that the player just landed on the ground, it determines how far below the player the ground is (which could be as many as 2 units below), finds any triggers that are in this space between the player and the ground, and manually signals to the engine that the player is touching these triggers (if the player was not already touching them).

The rationale behind this is that, if the player is "landed" on the ground, then their hitbox logically must extend all the way to the ground, and thus any triggers in such space should activate. This fix is pretty easy to justify and likely would have been handled better in the engine itself if not for the fact that it *really* only matters in maps made for movement game modes, as thin ground triggers do not come into play in first-party content (and neither does autobhop). Occurrences of this issue are more prevalent on **higher** tickrates.

---
**Telehops** [Post-tick]

If the plugin detects that a `trigger_teleport` was activated during this tick, the player did *not* activate one the previous tick, and either:
* The plugin predicted right before the tick that a collision would occur during this tick (resulting in a change / loss of velocity)
*or*
* The plugin detected that the client landed during the simulation of the tick (resulting in an instant removal of Z velocity)

Then the player's velocity is restored to the velocity they would have had after this tick (including any influence from key and mouse inputs) had the player not collided with -- or landed on -- anything.

The engine simulates each tick in a sequence of discrete steps, which to put it simply starts with a complete simulation of player movement including collisions with any solids, and only *after* this has finished does the engine check to see if the client is touching any triggers and activates them. This means it is not all that unlikely that a player will collide with something inside of or behind a thin `trigger_teleport` before triggering it, despite passing through it to even reach the point of collision. Occurrences of this issue are more prevalent on **lower** tickrates.

This fix is not applied if the player also activated a `trigger_teleport` on the previous tick to account for the speed-stopping teleport hubs some mappers use, especially on surf maps. These hubs typically teleport the player into a tiny box (or even inside a clip brush), and then at that location the player activates another `trigger_teleport` -- or sometimes one of several based on their `targetname` or `classname`. These are explicitly set up to stop the player's speed, and thus the fix should not be applied.

---
**Stair Sliding** [Post-tick]

The plugin checks if the following conditions are true:
1. The plugin predicted that a collision with a vertical surface would occur during this tick.
2. There is walkable ground directly below the point of collision, within the maximum step size (generally, 18.0 units).
3. If the player were to stand on the ground below the point of collision, they would activate no triggers.
4. From the ground below the point of collision, the surface collided with can be stepped up (the step must be as high as the maximum step size at most, there is nothing above the player that prevents the player from traveling up that distance, and the surface on top of the step must be walkable).

If all of these conditions are true, then the player is placed just barely on top of the stair step they just collided with, and the velocity they would have had if they had not collided with the face of the stair step is restored. This issue is mostly unaffected by tickrate.

This fix is only applied on surf maps (maps starting with `surf_`) because it can save a bhopping player from losing all of their speed if they barely hit a small single step even if they had no intention of sliding. Stairs are very uncommonly found on bhop maps, and even then I can't say I've ever seen a staircase that was worth sliding up as part of an optimal route, so the fix is really not needed on bhop anyway.
