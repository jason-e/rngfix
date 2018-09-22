# RNGFix

[![RNGFix Demo Video](https://i.imgur.com/YYm16Qh.png)](https://www.youtube.com/watch?v=PlMjHAQ90G8)

RNGFix is a [SourceMod](https://www.sourcemod.net/about.php) plugin that fixes a number of physics bugs that show up in movement-based game modes like bhop and surf. These issues are related in that they all appear to happen at random -- as far as a human player can tell.

Another plugin, [Slope Landing Fix (Slopefix)](https://forums.alliedmods.net/showthread.php?p=2322788), fixes the first of these issues (downhill inclines) and is seen as a necessity for both bhop and surf. RNGFix follows the spirit of this plugin by expanding on it with fixes for many more pseudo-random bugs.

Nothing this plugin does is impossible otherwise -- it just keeps random chance from mattering.

## Dependencies

* **SourceMod 1.10 - Build 6326 or newer**

The trigger jumping fix makes use of ray trace functionality added to SourceMod in in August 2018.
	
* [**DHooks**](https://forums.alliedmods.net/showthread.php?t=180114) 

* MarkTouching Extension (included)
This simply exposes the function `IServerGameEnts::MarkEntitiesAsTouching` for this plugin to use.

* (Optional, CS:GO) [Movement Unlocker](https://forums.alliedmods.net/showthread.php?t=255298)
Enables sliding on CS:GO. If you don't care about sliding on surf and the stair sliding fix, you don't need this.

Also, remember that you should stop using Slopefix if using RNGFix.

## Fixes

**Downhill Inclines**
		
Sometimes a player will not be "boosted" when falling onto an inclined surface, specifically while moving downhill. This fix results in the player always getting boosted. This is the scenario addressed by the original slopefix. RNGFix also implements this fix in a way that does not cause double boosts when a `trigger_push` is on the incline, which is a problem the original slopefix had.


**Uphill Inclines**

When bhopping *up* an incline, sometimes the player loses speed on the initial jump, and sometimes they do not. This fix makes it so the player never loses speed in this scenario, as long as it was possible for the player to not lose speed, if not for the "luck" factor that makes this random. On shallow inclines and uneven ground, this means you will no longer randomly lose small amounts of speed when jumping, and on steep inclines this means you no longer need to land sideways and then turn directly up them, which was just a method for maximizing favorable odds.


**Trigger Jumping**

Triggers that extend less than 2 units above the ground can sometimes be "jumped on" without activating them. This fix prevents this bug from occuring. This fixes annoyances like jumping on thin boosters without activating them, as well as exploitable behavior such as jumping on thin teleport triggers without activating them.


**Telehops**

It is possible to pass through a teleport trigger so quickly that you also collide with the wall (or floor) behind it before actually being teleported, despite touching the teleporter "first". This fix makes it impossible to both collide with a surface and activate a teleport in the same tick. This is most notably useful on staged bhop maps with thin stage-end teleports positioned against walls; with this fix you no longer need to go through them at an angle just to maximize the odds of keeping your speed.


**Edge Bugs**

When moving at high speed and landing on the extreme trailing edge of a platform, it is possible to collide with the surface -- resulting in a loss of vertical speed -- but without jumping, despite pressing jump in time (or holding jump with auto-bhop enabled). This fix causes the player to always be able to jump in this scenario. Note that you are still able to slide off by not pressing jump, if you wish to do so.

**Stair Sliding** (Surf Only)

The Source engine lets you move up stairs without requiring you to actually jump up each step -- as if the stairs were a simple incline -- and if you are moving fast this means you can slide up them quickly as well (on CSGO, sliding requires [Movement Unlocker](https://forums.alliedmods.net/showthread.php?t=255298)). However, if you are airborne and try to land on them at high speed, you may collide with the vertical face of a stair step before landing on top of a step, which results in a loss of speed and likely no slide. In the interest of making the incline-like behavior of stairs more consistent, this fix lets you slide up stairs when landing on them even if you hit the side of a stair step before the top of one.  

This fix will only be applied on surf maps (maps starting with `surf_`) because it has undesirable side-effects on bhop maps. It is also unlikely to be useful on bhop.

---
A more technical explanation of these fixes can be found [here](tech.md).

## Settings

The fixes can be disabled individually by setting the following cvars to `0` in `cfg/sourcemod/plugin.rngfix.cfg`. All fixes are enabled by default.
	
`rngfix_downhill`

`rngfix_uphill`

`rngfix_triggerjump`

`rngfix_telehop`

`rngfix_edge`

`rngfix_stairs`
