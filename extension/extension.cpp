#include "extension.h"

MarkTouching g_MarkTouching;		/**< Global singleton for extension's main interface */
IServerGameEnts *gameents = NULL;

SMEXT_LINK(&g_MarkTouching);

void MarkTouching::SDK_OnAllLoaded()
{
	sharesys->AddNatives(myself, MyNatives);
}

bool MarkTouching::SDK_OnMetamodLoad(ISmmAPI *ismm, char *error, size_t maxlen, bool late)
{
	GET_V_IFACE_ANY(GetServerFactory, gameents, IServerGameEnts, INTERFACEVERSION_SERVERGAMEENTS);

	return true;
}

cell_t MarkEntitiesAsTouching(IPluginContext *pContext, const cell_t *params)
{
	edict_t *pEdict1 = gamehelpers->EdictOfIndex(params[1]);
	if (!pEdict1 || pEdict1->IsFree())
	{
		return pContext->ThrowNativeError("Entity %d is invalid", params[1]);
	}

	edict_t *pEdict2 = gamehelpers->EdictOfIndex(params[2]);
	if (!pEdict2 || pEdict2->IsFree())
	{
		return pContext->ThrowNativeError("Entity %d is invalid", params[2]);
	}

	gameents->MarkEntitiesAsTouching(pEdict1, pEdict2);

	return true;
}

sp_nativeinfo_t MyNatives[] =
{
	{"MarkEntitiesAsTouching",	MarkEntitiesAsTouching},
	{NULL,			NULL},
};
