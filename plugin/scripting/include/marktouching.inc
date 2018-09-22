#if defined _marktouching_included
 #endinput
#endif
#define _marktouching_included

/**
 * Mark two entities as touching each other
 * This is the same call that is triggered when two entities touch, and triggers StartTouch, Touch, and later EndTouch.
 * Note that this will fire Touch() even if the entities were already touching, meaning Touch() will be called multiple times in one tick
 *
 * @param entity1			Entity index.
 * @param entity2			Entity index.
 * @noreturn
 */
native void MarkEntitiesAsTouching(int entity1, int entity2);

#if !defined REQUIRE_EXTENSIONS
public __ext_marktouching_SetNTVOptional()
{
	MarkNativeAsOptional("MarkEntitiesAsTouching");
}
#endif

public Extension __ext_marktouching = 
{
	name = "MarkTouching",
	file = "marktouching.ext",
#if defined AUTOLOAD_EXTENSIONS
	autoload = 1,
#else
	autoload = 0,
#endif
#if defined REQUIRE_EXTENSIONS
	required = 1,
#else
	required = 0,
#endif
};
