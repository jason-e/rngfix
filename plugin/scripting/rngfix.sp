#include <sdktools>
#include <sdkhooks>

#include <dhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.1.2"

public Plugin myinfo =
{
	name = "RNGFix",
	author = "rio",
	description = "Fixes physics bugs in movement game modes",
	version = PLUGIN_VERSION,
	url = "https://github.com/jason-e/rngfix"
}

// Engine constants, NOT settings (do not change)
#define LAND_HEIGHT 2.0 					// Maximum height above ground at which you can "land"
#define NON_JUMP_VELOCITY 140.0 			// Maximum Z velocity you are allowed to have and still land
#define MIN_STANDABLE_ZNRM 0.7				// Minimum surface normal Z component of a walkable surface
#define AIR_SPEED_CAP 30.0					// Constant used to limit air acceleration
#define DUCK_MIN_DUCKSPEED 1.5  			// Minimum duckspeed to start ducking
#define DEFAULT_JUMP_IMPULSE 301.99337741 	// sqrt(2 * 57.0 units * 800.0 u/s^2)

float g_vecMins[3];
float g_vecMaxsUnducked[3];
float g_vecMaxsDucked[3];
float g_flDuckDelta;

int g_iTick[MAXPLAYERS+1];
float g_flFrameTime[MAXPLAYERS+1];

bool g_bTouchingTrigger[MAXPLAYERS+1][2048];

int g_iButtons[MAXPLAYERS+1];
float g_vVel[MAXPLAYERS+1][3];
float g_vAngles[MAXPLAYERS+1][3];
int g_iOldButtons[MAXPLAYERS+1];

int g_iLastTickPredicted[MAXPLAYERS+1];

float g_vPreCollisionVelocity[MAXPLAYERS+1][3];
float g_vLastBaseVelocity[MAXPLAYERS+1][3];
int g_iLastGroundEnt[MAXPLAYERS+1];
int g_iLastLandTick[MAXPLAYERS+1];
int g_iLastCollisionTick[MAXPLAYERS+1];
int g_iLastMapTeleportTick[MAXPLAYERS+1];
bool g_bMapTeleportedSequentialTicks[MAXPLAYERS+1];
float g_vCollisionPoint[MAXPLAYERS+1][3];
float g_vCollisionNormal[MAXPLAYERS+1][3];

enum
{
	UPHILL_LOSS = -1,	// Force a jump, AND negatively affect speed as if a collision occurred (fix RNG not in player's favor)
	UPHILL_DEFAULT = 0, // Do nothing (retain RNG)
	UPHILL_NEUTRAL = 1	// Force a jump (respecting NON_JUMP_VELOCITY) (fix RNG in player's favor)
}

// Plugin settings
ConVar g_cvDownhill;
ConVar g_cvUphill;
ConVar g_cvEdge;
ConVar g_cvTriggerjump;
ConVar g_cvTelehop;
ConVar g_cvStairs;
ConVar g_cvUseOldSlopefixLogic;
ConVar g_cvDebug;

// Core physics ConVars
ConVar g_cvMaxVelocity;
ConVar g_cvGravity;
ConVar g_cvAirAccelerate;

// In CSS and CSGO but apparently not used in CSS
ConVar g_cvTimeBetweenDucks;

// CSGO-only
ConVar g_cvJumpImpulse;
ConVar g_cvAutoBunnyHopping;

Handle g_hPassesTriggerFilters;
Handle g_hProcessMovementHookPre;
Address g_IServerGameEnts;
Handle g_hMarkEntitiesAsTouching;

bool g_bIsSurfMap;

bool g_bLateLoad;

int g_iLaserIndex;
int g_color1[] = {0, 100, 255, 255};
int g_color2[] = {0, 255, 0, 255};

void DebugMsg(int client, const char[] fmt, any ...)
{
	if (!g_cvDebug.BoolValue) return;

	char output[1024];
	VFormat(output, sizeof(output), fmt, 3);
	PrintToConsole(client, "[%i] %s", g_iTick[client], output);
}

void DebugLaser(int client, const float p1[3], const float p2[3], float life, float width, const int color[4])
{
	if (g_cvDebug.IntValue < 2) return;

	TE_SetupBeamPoints(p2, p1, g_iLaserIndex, 0, 0, 0, life, width, width, 10, 0.0, color, 0);
	TE_SendToClient(client);
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
   g_bLateLoad = late;
   return APLRes_Success;
}

public void OnPluginStart()
{
	EngineVersion engine = GetEngineVersion();

	if (engine != Engine_CSGO && engine != Engine_CSS)
	{
		SetFailState("Game is not supported");
	}

	g_vecMins 		  = view_as<float>({-16.0, -16.0, 0.0});
	g_vecMaxsUnducked = view_as<float>({16.0, 16.0, 0.0});
	g_vecMaxsDucked   = view_as<float>({16.0, 16.0, 0.0});

	switch (engine)
	{
		case Engine_CSGO:
		{
			g_vecMaxsUnducked[2] = 72.0;
			g_vecMaxsDucked[2]   = 64.0;
		}
		case Engine_CSS:
		{
			g_vecMaxsUnducked[2] = 62.0;
			g_vecMaxsDucked[2]   = 45.0;
		}
	}

	g_flDuckDelta = (g_vecMaxsUnducked[2]-g_vecMaxsDucked[2]) / 2;

	g_cvDownhill 	= CreateConVar("rngfix_downhill", "1", "Enable downhill incline fix.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvUphill 		= CreateConVar("rngfix_uphill", "1", "Enable uphill incline fix. Set to -1 to normalize effects not in the player's favor (not recommended).", FCVAR_NOTIFY, true, -1.0, true, 1.0);
	g_cvEdge 		= CreateConVar("rngfix_edge", "1", "Enable edgebug fix.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvTriggerjump = CreateConVar("rngfix_triggerjump", "1", "Enable trigger jump fix.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvTelehop 	= CreateConVar("rngfix_telehop", "1", "Enable telehop fix.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvStairs		= CreateConVar("rngfix_stairs", "1", "Enable stair slide fix (surf only). You must have Movement Unlocker for sliding to work on CSGO.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvUseOldSlopefixLogic = CreateConVar("rngfix_useoldslopefixlogic", "0", "Old Slopefix had some logic errors that could cause double boosts. Enable this on a per-map basis to retain old behavior. (NOT RECOMMENDED)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvDebug = CreateConVar("rngfix_debug", "0", "1 = Enable debug messages. 2 = Enable debug messages and lasers.", _, true, 0.0, true, 2.0);

	AutoExecConfig();

	g_cvMaxVelocity   = FindConVar("sv_maxvelocity");
	g_cvGravity 	  = FindConVar("sv_gravity");
	g_cvAirAccelerate = FindConVar("sv_airaccelerate");

	if (g_cvMaxVelocity == null || g_cvGravity == null || g_cvAirAccelerate == null)
	{
		SetFailState("Could not find all ConVars");
	}

	// Not required
	g_cvTimeBetweenDucks = FindConVar("sv_timebetweenducks");
	g_cvJumpImpulse		 = FindConVar("sv_jump_impulse");
	g_cvAutoBunnyHopping = FindConVar("sv_autobunnyhopping");

	Handle gamedataConf = LoadGameConfigFile("rngfix.games");
	if (gamedataConf == null) SetFailState("Failed to load rngfix gamedata");

	// PassesTriggerFilters
	StartPrepSDKCall(SDKCall_Entity);
	if (!PrepSDKCall_SetFromConf(gamedataConf, SDKConf_Virtual, "CBaseTrigger::PassesTriggerFilters"))
	{
		SetFailState("Failed to get CBaseTrigger::PassesTriggerFilters offset");
	}
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
	g_hPassesTriggerFilters = EndPrepSDKCall();

	if (g_hPassesTriggerFilters == null) SetFailState("Unable to prepare SDKCall for CBaseTrigger::PassesTriggerFilters");

	// CreateInterface
	// Thanks SlidyBat and ici
	StartPrepSDKCall(SDKCall_Static);
	if (!PrepSDKCall_SetFromConf(gamedataConf, SDKConf_Signature, "CreateInterface"))
	{
		SetFailState("Failed to get CreateInterface");
	}
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Pointer, VDECODE_FLAG_ALLOWNULL);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	Handle CreateInterface = EndPrepSDKCall();

	if (CreateInterface == null) SetFailState("Unable to prepare SDKCall for CreateInterface");

	char interfaceName[64];

	// ProcessMovement
	if (!GameConfGetKeyValue(gamedataConf, "IGameMovement", interfaceName, sizeof(interfaceName)))
	{
		SetFailState("Failed to get IGameMovement interface name");
	}
	Address IGameMovement = SDKCall(CreateInterface, interfaceName, 0);
	if (!IGameMovement)
	{
		SetFailState("Failed to get IGameMovement pointer");
	}

	int offset = GameConfGetOffset(gamedataConf, "ProcessMovement");
	if (offset == -1) SetFailState("Failed to get ProcessMovement offset");

	g_hProcessMovementHookPre = DHookCreate(offset, HookType_Raw, ReturnType_Void, ThisPointer_Ignore, DHook_ProcessMovementPre);
	DHookAddParam(g_hProcessMovementHookPre, HookParamType_CBaseEntity);
	DHookAddParam(g_hProcessMovementHookPre, HookParamType_ObjectPtr);
	DHookRaw(g_hProcessMovementHookPre, false, IGameMovement);

	// MarkEntitiesAsTouching
	if (!GameConfGetKeyValue(gamedataConf, "IServerGameEnts", interfaceName, sizeof(interfaceName)))
	{
		SetFailState("Failed to get IServerGameEnts interface name");
	}
	g_IServerGameEnts = SDKCall(CreateInterface, interfaceName, 0);
	if (!g_IServerGameEnts)
	{
		SetFailState("Failed to get IServerGameEnts pointer");
	}

	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(gamedataConf, SDKConf_Virtual, "IServerGameEnts::MarkEntitiesAsTouching"))
	{
		SetFailState("Failed to get IServerGameEnts::MarkEntitiesAsTouching offset");
	}
	PrepSDKCall_AddParameter(SDKType_Edict, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_Edict, SDKPass_Pointer);
	g_hMarkEntitiesAsTouching = EndPrepSDKCall();

	if (g_hMarkEntitiesAsTouching == null) SetFailState("Unable to prepare SDKCall for IServerGameEnts::MarkEntitiesAsTouching");

	delete CreateInterface;
	delete gamedataConf;

	if (g_bLateLoad)
	{
		for (int client = 1; client <= MaxClients; client++)
		{
			if (IsClientInGame(client)) OnClientPutInServer(client);
		}

		char classname[64];
		for (int entity = MaxClients+1; entity < sizeof(g_bTouchingTrigger[]); entity++)
		{
			if (!IsValidEntity(entity)) continue;
			GetEntPropString(entity, Prop_Data, "m_iClassname", classname, sizeof(classname));
			HookTrigger(entity, classname);
		}
	}
}

public void OnMapStart()
{
	g_iLaserIndex = PrecacheModel("materials/sprites/laserbeam.vmt", true);

	char map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	g_bIsSurfMap = StrContains(map, "surf_", false) == 0;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (entity >= sizeof(g_bTouchingTrigger[])) return;
	HookTrigger(entity, classname);
}

void HookTrigger(int entity, const char[] classname)
{
	if (StrContains(classname, "trigger_") != -1)
	{
		SDKHook(entity, SDKHook_StartTouchPost, Hook_TriggerStartTouch);
		SDKHook(entity, SDKHook_EndTouchPost, Hook_TriggerEndTouch);
	}

	if (StrContains(classname, "trigger_teleport") != -1)
	{
		SDKHook(entity, SDKHook_TouchPost, Hook_TriggerTeleportTouchPost);
	}
}

public void OnClientConnected(int client)
{
	g_iTick[client] = 0;
	for (int i = 0; i < sizeof(g_bTouchingTrigger[]); i++) g_bTouchingTrigger[client][i] = false;
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_GroundEntChangedPost, Hook_PlayerGroundEntChanged);
	SDKHook(client, SDKHook_PostThink, Hook_PlayerPostThink);
}

public Action Hook_TriggerStartTouch(int entity, int other)
{
	if (1 <= other <= MaxClients)
	{
		g_bTouchingTrigger[other][entity] = true;
		DebugMsg(other, "StartTouch %i", entity);
	}

	return Plugin_Continue;
}

// TODO Would be nice to have IServerTools::FindEntityByName / CGlobalEntityList::FindEntityByName
bool NameExists(const char[] targetname)
{
	// Assume special types exist
	if (targetname[0] == '!') return true;

	char targetname2[128];

	int max = GetMaxEntities();
	for (int entity = 1; entity < max; entity++)
	{
		if (!IsValidEntity(entity)) continue;
		if (GetEntPropString(entity, Prop_Data, "m_iName", targetname2, sizeof(targetname2)) == 0) continue;

		if (StrEqual(targetname, targetname2)) return true;
	}

	return false;
}

public void Hook_TriggerTeleportTouchPost(int entity, int other)
{
	if (!(1 <= other <= MaxClients)) return;

	if (!SDKCall(g_hPassesTriggerFilters, entity, other)) return;

	char targetstring[128];
	if (GetEntPropString(entity, Prop_Data, "m_target", targetstring, sizeof(targetstring)) == 0) return;

	if (!NameExists(targetstring)) return;

	if (g_iLastMapTeleportTick[other] == g_iTick[other]-1)
	{
		g_bMapTeleportedSequentialTicks[other] = true;
	}

	g_iLastMapTeleportTick[other] = g_iTick[other];

	DebugMsg(other, "Triggered teleport %i", entity);
}

public Action Hook_TriggerEndTouch(int entity, int other)
{
	if (1 <= other <= MaxClients)
	{
	 	g_bTouchingTrigger[other][entity] = false;
	 	DebugMsg(other, "EndTouch %i", entity);
	}
	return Plugin_Continue;
}

public bool PlayerFilter(int entity, int mask)
{
	return !(1 <= entity <= MaxClients);
}

float GetJumpImpulse()
{
	if (g_cvJumpImpulse != null)
	{
		return g_cvJumpImpulse.FloatValue;
	}
	else
	{
		return DEFAULT_JUMP_IMPULSE;
	}
}

bool IsDuckCoolingDown(int client)
{
	// TODO Is this stuff in MoveData?

	// Ducking is prevented if the last switch to a ducked state from an unducked state is sooner than sv_timebetweenducks ago.
	// Note: This cooldown is based on client's curtime (GetGameTime() in this context) and thus is unaffected by m_flLaggedMovementValue.
	if (g_cvTimeBetweenDucks != null && HasEntProp(client, Prop_Data, "m_flLastDuckTime"))
	{
		if (GetGameTime() - GetEntPropFloat(client, Prop_Data, "m_flLastDuckTime") < g_cvTimeBetweenDucks.FloatValue) return true;
	}

	// m_flDuckSpeed is decreased by 2.0 to a minimum of 0.0 every time the duck key is pressed OR released.
	// It recovers at a rate of 3.0 * m_flLaggedMovementValue per second and caps at 8.0.
	// Switching to a ducked state from an unducked state is prevented if it is less than 1.5.
	if (HasEntProp(client, Prop_Data, "m_flDuckSpeed"))
	{
		if (GetEntPropFloat(client, Prop_Data, "m_flDuckSpeed") < DUCK_MIN_DUCKSPEED) return true;
	}

	return false;
}

void Duck(int client, float origin[3], float mins[3], float maxs[3])
{
	bool ducking = GetEntityFlags(client) & FL_DUCKING != 0;

	bool nextDucking = ducking;

	if (g_iButtons[client] & IN_DUCK != 0 && !ducking)
	{
		if (!IsDuckCoolingDown(client))
		{
			origin[2] += g_flDuckDelta;
			nextDucking = true;
		}
	}
	else if (g_iButtons[client] & IN_DUCK == 0 && ducking)
	{
		origin[2] -= g_flDuckDelta;

		TR_TraceHullFilter(origin, origin, g_vecMins, g_vecMaxsUnducked, MASK_PLAYERSOLID, PlayerFilter);

		// Cannot unduck in air, not enough room
		if (TR_DidHit()) origin[2] += g_flDuckDelta;
		else nextDucking = false;
	}

	mins = g_vecMins;
	maxs = nextDucking ? g_vecMaxsDucked : g_vecMaxsUnducked;
}

bool CanJump(int client)
{
	if (g_iButtons[client] & IN_JUMP == 0) return false;
	if (g_iOldButtons[client] & IN_JUMP != 0 && !(g_cvAutoBunnyHopping != null && g_cvAutoBunnyHopping.BoolValue)) return false;

	return true;
}

void CheckJumpButton(int client, float velocity[3])
{
	// Skip dead and water checks since we already did them.

	// We need to check for ground somewhere so stick it here.
	if (GetEntityFlags(client) & FL_ONGROUND == 0) return;

	if (!CanJump(client)) return;

	// TODO Incorporate surfacedata jump factor

	// This conditional is why jumping while crouched jumps higher! Bad!
	if (GetEntProp(client, Prop_Data, "m_bDucking") != 0 || GetEntityFlags(client) & FL_DUCKING != 0)
	{
		velocity[2] = GetJumpImpulse();
	}
	else
	{
		velocity[2] += GetJumpImpulse();
	}

	// Jumping does an extra half tick of gravity! Bad!
	FinishGravity(client, velocity);
}

void AirAccelerate(int client, float velocity[3], Handle hParams)
{
	// This also includes the initial parts of AirMove()

	float fore[3], side[3];
	float wishvel[3], wishdir[3];

	GetAngleVectors(g_vAngles[client], fore, side, NULL_VECTOR);

	fore[2] = 0.0;
	side[2] = 0.0;
	NormalizeVector(fore, fore);
	NormalizeVector(side, side);

	for (int i = 0; i < 2; i++)	wishvel[i] = fore[i] * g_vVel[client][0] + side[i] * g_vVel[client][1];

	float wishspeed = NormalizeVector(wishvel, wishdir);
	float m_flMaxSpeed = DHookGetParamObjectPtrVar(hParams, 2, 56, ObjectValueType_Float);
	if (wishspeed > m_flMaxSpeed && m_flMaxSpeed != 0.0) wishspeed = m_flMaxSpeed;

	if (wishspeed)
	{
		float wishspd = wishspeed;
		if (wishspd > AIR_SPEED_CAP) wishspd = AIR_SPEED_CAP;

		float currentspeed = GetVectorDotProduct(velocity, wishdir);
		float addspeed = wishspd - currentspeed;

		if (addspeed > 0)
		{
			float accelspeed = g_cvAirAccelerate.FloatValue * wishspeed * g_flFrameTime[client];
			if (accelspeed > addspeed) accelspeed = addspeed;

			for (int i = 0; i < 2; i++) velocity[i] += accelspeed * wishdir[i];
		}
	}
}

void CheckVelocity(float velocity[3])
{
	for (int i = 0; i < 3; i++)
	{
		if 		(velocity[i] >  g_cvMaxVelocity.FloatValue) velocity[i] =  g_cvMaxVelocity.FloatValue;
		else if (velocity[i] < -g_cvMaxVelocity.FloatValue) velocity[i] = -g_cvMaxVelocity.FloatValue;
	}
}

void StartGravity(int client, float velocity[3])
{
	float localGravity = GetEntPropFloat(client, Prop_Data, "m_flGravity");
	if (localGravity == 0.0) localGravity = 1.0;

	velocity[2] -= localGravity * g_cvGravity.FloatValue * 0.5 * g_flFrameTime[client];

	float baseVelocity[3];
	GetEntPropVector(client, Prop_Data, "m_vecBaseVelocity", baseVelocity);
	velocity[2] += baseVelocity[2] * g_flFrameTime[client];

	// baseVelocity[2] would get cleared here but we shouldn't do that since this is just a prediction.

	CheckVelocity(velocity);
}

void FinishGravity(int client, float velocity[3])
{
	float localGravity = GetEntPropFloat(client, Prop_Data, "m_flGravity");
	if (localGravity == 0.0) localGravity = 1.0;

	velocity[2] -= localGravity * g_cvGravity.FloatValue * 0.5 * g_flFrameTime[client];

	CheckVelocity(velocity);
}

bool CheckWater(int client)
{
	// The cached water level is updated multiple times per tick, including after movement happens,
	// so we can just check the cached value here.
	return GetEntProp(client, Prop_Data, "m_nWaterLevel") > 1;
}

void PreventCollision(int client, Handle hParams, const float origin[3], const float collisionPoint[3], const float velocity_tick[3])
{
	DebugLaser(client, origin, collisionPoint, 15.0, 0.5, g_color1);

	// Rewind part of a tick so at the end of this tick	we will end up close to the ground without colliding with it.
	// This effectively simulates a mid-tick jump (we lose part of a tick but its a miniscule trade-off).
	// This is also only an approximation of a partial tick rewind but it's good enough.
	float newOrigin[3];
	SubtractVectors(collisionPoint, velocity_tick, newOrigin);

	// Add a little space between us and the ground so we don't accidentally hit it anyway, maybe due to floating point error or something.
	// I don't know if this is necessary but I would rather be safe.
	newOrigin[2] += 0.1;

	// Since the MoveData for this tick has already been filled and is about to be used, we need
	// to modify it directly instead of changing the player entity's actual position (such as with TeleportEntity).
	DHookSetParamObjectPtrVarVector(hParams, 2, GetEngineVersion() == Engine_CSGO ? 172 : 152, ObjectValueType_Vector, newOrigin);

	DebugLaser(client, origin, newOrigin, 15.0, 0.5, g_color2);

	float adjustment[3];
	SubtractVectors(newOrigin, origin, adjustment);
	DebugMsg(client, "Moved: %.2f %.2f %.2f", adjustment[0], adjustment[1], adjustment[2]);

	// No longer colliding this tick, clear our prediction flag
	g_iLastCollisionTick[client] = 0;
}

void ClipVelocity(const float velocity[3], const float nrm[3], float out[3])
{
	float backoff = GetVectorDotProduct(velocity, nrm);

	for (int i = 0; i < 3; i++)
	{
		out[i] = velocity[i] - nrm[i]*backoff;
	}

	// The adjust step only matters with overbounce which doesnt apply to walkable surfaces.
}

void SetVelocity(int client, float velocity[3], bool dontUseTeleportEntity = false)
{
	// Pull out basevelocity from desired true velocity
	// Use the pre-tick basevelocity because that is what influenced this tick's movement and the desired new velocity.
	SubtractVectors(velocity, g_vLastBaseVelocity[client], velocity);

	if (dontUseTeleportEntity && GetEntPropEnt(client, Prop_Data, "m_hMoveParent") == -1)
	{
		SetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", velocity);
		SetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);
	}
	else
	{
		float baseVelocity[3];
		GetEntPropVector(client, Prop_Data, "m_vecBaseVelocity", baseVelocity);

		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, velocity);

		// TeleportEntity with non-null velocity wipes out basevelocity, so restore it after.
		// Since we didn't change position, nothing should change regarding influences on basevelocity.
		SetEntPropVector(client, Prop_Data, "m_vecBaseVelocity", baseVelocity);
	}
}

public MRESReturn DHook_ProcessMovementPre(Handle hParams)
{
	int client = DHookGetParam(hParams, 1);

	g_iTick[client]++;
	g_flFrameTime[client] = GetTickInterval() * GetEntPropFloat(client, Prop_Data, "m_flLaggedMovementValue");
	g_bMapTeleportedSequentialTicks[client] = false;

	// If we are actually not doing ANY of the fixes that rely on pre-tick collision prediction, skip all this.
	if (!g_cvUphill.BoolValue && !g_cvEdge.BoolValue && !g_cvStairs.BoolValue && !g_cvTelehop.BoolValue && !g_cvDownhill.BoolValue)
	{
		return MRES_Ignored;
	}

	RunPreTickChecks(client, hParams);

	return MRES_Ignored;
}

void RunPreTickChecks(int client, Handle hParams)
{
	// Recreate enough of CGameMovement::ProcessMovement to predict if fixes are needed.
	// We only really care about a limited set of scenarios (less than waist-deep in water, MOVETYPE_WALK, air movement).

	if (!IsPlayerAlive(client)) return;
	if (GetEntityMoveType(client) != MOVETYPE_WALK) return;
	if (CheckWater(client)) return;

	g_iLastGroundEnt[client] = GetEntPropEnt(client, Prop_Data, "m_hGroundEntity");

	// If we are definitely staying on the ground this tick, don't predict it.
	if (g_iLastGroundEnt[client] != -1 && !CanJump(client)) return;

	g_iLastTickPredicted[client] = g_iTick[client];

	g_iButtons[client] = DHookGetParamObjectPtrVar(hParams, 2, 36, ObjectValueType_Int);
	g_iOldButtons[client] = DHookGetParamObjectPtrVar(hParams, 2, 40, ObjectValueType_Int);
	DHookGetParamObjectPtrVarVector(hParams, 2, 44, ObjectValueType_Vector, g_vVel[client]);
	DHookGetParamObjectPtrVarVector(hParams, 2, 12, ObjectValueType_Vector, g_vAngles[client]);

	float velocity[3];
	DHookGetParamObjectPtrVarVector(hParams, 2, 64, ObjectValueType_Vector, velocity);

	float baseVelocity[3];
	// basevelocity is not stored in MoveData
	GetEntPropVector(client, Prop_Data, "m_vecBaseVelocity", baseVelocity);

	float origin[3];
	DHookGetParamObjectPtrVarVector(hParams, 2, GetEngineVersion() == Engine_CSGO ? 172 : 152, ObjectValueType_Vector, origin);

	float nextOrigin[3], mins[3], maxs[3];

	nextOrigin = origin;

	// These roughly replicate the behavior of their equivalent CGameMovement functions.

	Duck(client, nextOrigin, mins, maxs);

	StartGravity(client, velocity);

	CheckJumpButton(client, velocity);

	CheckVelocity(velocity);

	AirAccelerate(client, velocity, hParams);

	// StartGravity dealt with Z basevelocity.
	baseVelocity[2] = 0.0;
	g_vLastBaseVelocity[client] = baseVelocity;
	AddVectors(velocity, baseVelocity, velocity);

	// Store this for later in case we need to undo the effects of a collision.
	g_vPreCollisionVelocity[client] = velocity;

	// This is basically where TryPlayerMove happens.
	// We don't really care about anything after TryPlayerMove either.

	float velocity_tick[3];
	velocity_tick = velocity;
	ScaleVector(velocity_tick, g_flFrameTime[client]);

	AddVectors(nextOrigin, velocity_tick, nextOrigin);

	// Check if we will hit something this tick.
	TR_TraceHullFilter(origin, nextOrigin, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);

	if (TR_DidHit())
	{
		float nrm[3];
		TR_GetPlaneNormal(null, nrm);

		if (g_iLastCollisionTick[client] < g_iTick[client]-1)
		{
			DebugMsg(client, "Collision predicted! (normal: %.3f %.3f %.3f)", nrm[0], nrm[1], nrm[2]);
		}

		float collisionPoint[3];
		TR_GetEndPosition(collisionPoint);

		// Store this result for post-tick fixes.
		g_iLastCollisionTick[client] = g_iTick[client];
		g_vCollisionPoint[client] = collisionPoint;
		g_vCollisionNormal[client] = nrm;

		// If we are moving up too fast, we can't land anyway so these fixes aren't needed.
		if (velocity[2] > NON_JUMP_VELOCITY) return;

		// Landing also requires a walkable surface.
		// This will give false negatives if the surface initially collided
		// is too steep but the final one isn't (rare and unlikely to matter).
		if (nrm[2] < MIN_STANDABLE_ZNRM) return;

		// Check uphill incline fix first since it's more common and faster.
		if (g_cvUphill.IntValue == UPHILL_NEUTRAL)
		{
			// Make sure it's not flat, and that we are actually going uphill (X/Y dot product < 0.0)
			if (nrm[2] < 1.0 && nrm[0]*velocity[0] + nrm[1]*velocity[1] < 0.0)
			{
				bool shouldDoDownhillFixInstead = false;

				if (g_cvDownhill.BoolValue)
				{
					// We also want to make sure this isn't a case where it's actually more beneficial to do the downhill fix.
					float newVelocity[3];
					ClipVelocity(velocity, nrm, newVelocity);

					if (newVelocity[0]*newVelocity[0] + newVelocity[1]*newVelocity[1] > velocity[0]*velocity[0] + velocity[1]*velocity[1])
					{
						shouldDoDownhillFixInstead = true;
					}
				}

				if (!shouldDoDownhillFixInstead)
				{
					DebugMsg(client, "DO FIX: Uphill Incline");
					PreventCollision(client, hParams, origin, collisionPoint, velocity_tick);

					// This naturally prevents any edge bugs so we can skip the edge fix.
					return;
				}
			}
		}

		if (g_cvEdge.BoolValue)
		{
			// Do a rough estimate of where we will be at the end of the tick after colliding.
			// This method assumes no more collisions will take place after the first.
			// There are some very extreme circumstances where this will give false positives (unlikely to come into play).

			float tickEnd[3];
			float fraction_left = 1.0 - TR_GetFraction();

			if (nrm[2] == 1.0)
			{
				// If the ground is level, all that changes is Z velocity becomes zero.
				tickEnd[0] = collisionPoint[0] + velocity_tick[0]*fraction_left;
				tickEnd[1] = collisionPoint[1] + velocity_tick[1]*fraction_left;
				tickEnd[2] = collisionPoint[2];
			}
			else
			{
				float velocity2[3];
				ClipVelocity(velocity, nrm, velocity2);

				if (velocity2[2] > NON_JUMP_VELOCITY)
				{
					// This would be an "edge bug" (slide without landing at the end of the tick)
					// 100% of the time due to the Z velocity restriction.
					return;
				}
				else
				{
					ScaleVector(velocity2, g_flFrameTime[client]*fraction_left);
					AddVectors(collisionPoint, velocity2, tickEnd);
				}
			}

			// Check if there's something close enough to land on below the player at the end of this tick.
			float tickEndBelow[3];
			tickEndBelow[0] = tickEnd[0];
			tickEndBelow[1] = tickEnd[1];
			tickEndBelow[2] = tickEnd[2] - LAND_HEIGHT;

			TR_TraceHullFilter(tickEnd, tickEndBelow, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);

			if (TR_DidHit())
			{
				// There's something there, can we land on it?
				float nrm2[3];
				TR_GetPlaneNormal(null, nrm2);

				// Yes, it's not too steep.
				if (nrm2[2] >= MIN_STANDABLE_ZNRM) return;
				// Yes, the quadrant check finds ground that isn't too steep.
				if (TracePlayerBBoxForGround(tickEnd, tickEndBelow, mins, maxs)) return;
			}

			DebugMsg(client, "DO FIX: Edge Bug");
			DebugLaser(client, collisionPoint, tickEnd, 15.0, 0.5, g_color1);

			PreventCollision(client, hParams, origin, collisionPoint, velocity_tick);
		}
	}
}

public void Hook_PlayerGroundEntChanged(int client)
{
	// We cannot get the new ground entity at this point,
	// but if the previous value was -1, it must be something else now, so we landed.
	if (GetEntPropEnt(client, Prop_Data, "m_hGroundEntity") == -1)
	{
		g_iLastLandTick[client] = g_iTick[client];
		DebugMsg(client, "Landed");
	}
}

bool DoTriggerjumpFix(int client, const float landingPoint[3], const float landingMins[3], const float landingMaxs[3])
{
	if (!g_cvTriggerjump.BoolValue) return false;

	// It's possible to land above a trigger but also in another trigger_teleport, have the teleport move you to
	// another location, and then the trigger jumping fix wouldn't fire the other trigger you technically landed above,
	// but I can't imagine a mapper would ever actually stack triggers like that.

	float origin[3];
	GetEntPropVector(client, Prop_Data, "m_vecAbsOrigin", origin);

	float landingMaxsBelow[3];
	landingMaxsBelow[0] = landingMaxs[0];
	landingMaxsBelow[1] = landingMaxs[1];
	landingMaxsBelow[2] = origin[2] - landingPoint[2];

	ArrayList triggers = new ArrayList();

	// Find triggers that are between us and the ground (using the bounding box quadrant we landed with if applicable).
	TR_EnumerateEntitiesHull(landingPoint, landingPoint, landingMins, landingMaxsBelow, true, AddTrigger, triggers);

	bool didSomething = false;

	for (int i = 0; i < triggers.Length; i++)
	{
		int trigger = triggers.Get(i);

		// MarkEntitiesAsTouching always fires the Touch function even if it was already fired this tick.
		// In case that could cause side-effects, manually keep track of triggers we are actually touching
		// and don't re-touch them.
		if (g_bTouchingTrigger[client][trigger]) continue;

		DebugMsg(client, "DO FIX: Trigger Jumping (entity %i)", trigger);

		SDKCall(g_hMarkEntitiesAsTouching, g_IServerGameEnts, client, trigger);
		didSomething = true;
	}

	delete triggers;

	return didSomething;
}

bool DoStairsFix(int client)
{
	if (!g_cvStairs.BoolValue) return false;
	if (g_iLastTickPredicted[client] != g_iTick[client]) return false;

	// This fix has undesirable side-effects on bhop. It is also very unlikely to help on bhop.
	if (!g_bIsSurfMap) return false;

	// Let teleports take precedence (including teleports activated by the trigger jumping fix).
	if (g_iLastMapTeleportTick[client] == g_iTick[client]) return false;

	// If moving upward, the player would never be able to slide up with any current position.
	if (g_vPreCollisionVelocity[client][2] > 0.0) return false;

	// Stair step faces don't necessarily have to be completely vertical, but, if they are not,
	// sliding up them at high speed -- or even just walking up -- usually doesn't work.
	// Plus, it's really unlikely that there are actual stairs shaped like that.
	if (g_iLastCollisionTick[client] == g_iTick[client] && g_vCollisionNormal[client][2] == 0.0)
	{
		// Do this first and stop if we are moving slowly (less than 1 unit per tick).
		float velocity_dir[3];
		velocity_dir = g_vPreCollisionVelocity[client];
		velocity_dir[2] = 0.0;
		if (NormalizeVector(velocity_dir, velocity_dir) * g_flFrameTime[client] < 1.0) return false;

		float mins[3], maxs[3];
		GetEntPropVector(client, Prop_Data, "m_vecMins", mins);
		GetEntPropVector(client, Prop_Data, "m_vecMaxs", maxs);

		// We seem to have collided with a "wall", now figure out if it's a stair step.

		// Look for ground below us
		float stepsize = GetEntPropFloat(client, Prop_Data, "m_flStepSize");

		float end[3];
		end = g_vCollisionPoint[client];
		end[2] -= stepsize;

		TR_TraceHullFilter(g_vCollisionPoint[client], end, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);

		if (TR_DidHit())
		{
			float nrm[3];
			TR_GetPlaneNormal(null, nrm);

			// Ground below is not walkable, not stairs
			if (nrm[2] < MIN_STANDABLE_ZNRM) return false;

			float start[3];
			TR_GetEndPosition(start);

			// Find triggers that we would trigger if we did touch the ground here.
			ArrayList triggers = new ArrayList();

			TR_EnumerateEntitiesHull(start, start, mins, maxs, true, AddTrigger, triggers);

			for (int i = 0; i < triggers.Length; i++)
			{
				int trigger = triggers.Get(i);

				if (SDKCall(g_hPassesTriggerFilters, trigger, client))
				{
					// We would have triggered something on the ground here, so we cant be sure the stairs fix is safe to do.
					// The most likely scenario here is this isn't stairs, but just a short ledge with a fail teleport in front.
					delete triggers;
					return false;
				}
			}

			delete triggers;

			// Now follow CGameMovement::StepMove behavior.

			// Trace up
			end = start;
			end[2] += stepsize;
			TR_TraceHullFilter(start, end, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);

			if (TR_DidHit()) TR_GetEndPosition(end);

			// Trace over (only 1 unit, just to find a stair step)
			start = end;
			AddVectors(start, velocity_dir, end);

			TR_TraceHullFilter(start, end, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);

			if (TR_DidHit())
			{
				// The plane we collided with is too tall to be a stair step (i.e. it's a wall, not stairs).
				// Or possibly: the ceiling is too low to get on top of it.
				return false;
			}
			else
			{
				// Trace downward
				start = end;
				end[2] -= stepsize;

				TR_TraceHullFilter(start, end, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);

				if (!TR_DidHit()) return false; // Shouldn't happen

				TR_GetPlaneNormal(null, nrm);

				// Ground atop "stair" is not walkable, not stairs
				if (nrm[2] < MIN_STANDABLE_ZNRM) return false;

				// It looks like we actually collided with a stair step.
				// Put the player just barely on top of the stair step we found and restore their speed
				TR_GetEndPosition(end);

				DebugMsg(client, "DO FIX: Stair Sliding");

				TeleportEntity(client, end, NULL_VECTOR, NULL_VECTOR);
				SetVelocity(client, g_vPreCollisionVelocity[client]);

				return true;
			}
		}
	}

	return false;
}

bool DoInclineCollisionFixes(int client, const float nrm[3])
{
	if (!g_cvDownhill.BoolValue && g_cvUphill.IntValue != UPHILL_LOSS) return false;
	if (g_iLastTickPredicted[client] != g_iTick[client]) return false;

	// There's no point in checking for fix if we were moving up, unless we want to do an uphill collision
	if (g_vPreCollisionVelocity[client][2] > 0.0 && g_cvUphill.IntValue != UPHILL_LOSS) return false;

	// If a collision was predicted this tick (and wasn't prevented by another fix alrady), no fix is needed.
	// It's possible we actually have to run the edge bug fix and an incline fix in the same tick.
	// If using the old Slopefix logic, do the fix regardless of necessity just like Slopefix
	// so we can be sure to trigger a double boost if applicable.
	if (g_iLastCollisionTick[client] == g_iTick[client] && !g_cvUseOldSlopefixLogic.BoolValue) return false;

	// Make sure the ground is not level, otherwise a collision would do nothing important anyway.
	if (nrm[2] == 1.0) return false;

	// This velocity includes changes from player input this tick as well as
	// the half tick of gravity applied before collision would occur.
	float velocity[3];
	velocity = g_vPreCollisionVelocity[client];

	if (g_cvUseOldSlopefixLogic.BoolValue)
	{
		// The old slopefix did not consider basevelocity when calculating deflected velocity
		SubtractVectors(velocity, g_vLastBaseVelocity[client], velocity);
	}

	float dot = nrm[0]*velocity[0] + nrm[1]*velocity[1];

	if (dot >= 0)
	{
		// If going downhill, only adjust velocity if the downhill incline fix is on.
		if (!g_cvDownhill.BoolValue) return false;
	}

	bool downhillFixIsBeneficial = false;

	float newVelocity[3];
	ClipVelocity(velocity, nrm, newVelocity);

	if (newVelocity[0]*newVelocity[0] + newVelocity[1]*newVelocity[1] > velocity[0]*velocity[0] + velocity[1]*velocity[1])
	{
		downhillFixIsBeneficial = true;
	}

	if (dot < 0)
	{
		// If going uphill, only adjust velocity if uphill incline fix is set to loss mode
		// OR if this is actually a case where the downhill incline fix is better.
		if (!((downhillFixIsBeneficial && g_cvDownhill.BoolValue) || g_cvUphill.IntValue == UPHILL_LOSS)) return false;
	}

	DebugMsg(client, "DO FIX: Incline Collision (%s) (z-normal: %.3f)", downhillFixIsBeneficial ? "Downhill" : "Uphill", nrm[2]);

	// Make sure Z velocity is zero since we are on the ground.
	newVelocity[2] = 0.0;

	// Since we are on the ground, we also don't need to FinishGravity().

	if (g_cvUseOldSlopefixLogic.BoolValue)
	{
		// The old slopefix immediately moves basevelocity into local velocity to keep it from getting cleared.
		// This results in double boosts as the player is likely still being influenced by the source of the basevelocity.
		if (GetEntityFlags(client) & FL_BASEVELOCITY != 0)
		{
			float baseVelocity[3];
			GetEntPropVector(client, Prop_Data, "m_vecBaseVelocity", baseVelocity);
			AddVectors(newVelocity, baseVelocity, newVelocity);
		}

		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, newVelocity);
	}
	else
	{
		SetVelocity(client, newVelocity);
	}

	return true;
}

bool DoTelehopFix(int client)
{
	if (!g_cvTelehop.BoolValue) return false;
	if (g_iLastTickPredicted[client] != g_iTick[client]) return false;

	if (g_iLastMapTeleportTick[client] != g_iTick[client]) return false;

	// If the player was teleported two ticks in a row, don't do this fix because the player likely just passed
	// through a speed-stopping teleport hub, and the map really did want to stop the player this way.
	if (g_bMapTeleportedSequentialTicks[client]) return false;

	// Check if we either collided this tick OR landed during this tick.
	// Note that we could have landed this tick, lost Z velocity, then gotten teleported, making us no longer on the ground.
	// This is why we need to remember if we landed mid-tick rather than just check ground state now.
	if (!(g_iLastCollisionTick[client] == g_iTick[client] || g_iLastLandTick[client] == g_iTick[client])) return false;

	// At this point, ideally we should check if the teleport would have triggered "after" the collision (within the tick duration),
	// and, if so, not restore speed, but properly doing that would involve completely duplicating TryPlayerMove but with
	// multiple intermediate trigger checks which is probably a bad idea... better to just give people the benefit of the doubt sometimes.

	// Restore the velocity we would have had if we didn't collide or land.
	float newVelocity[3];
	newVelocity = g_vPreCollisionVelocity[client];

	// Don't forget to add the second half-tick of gravity ourselves.
	FinishGravity(client, newVelocity);

	float origin[3];
	GetEntPropVector(client, Prop_Data, "m_vecAbsOrigin", origin);

	float mins[3], maxs[3];
	GetEntPropVector(client, Prop_Data, "m_vecMins", mins);
	GetEntPropVector(client, Prop_Data, "m_vecMaxs", maxs);

	TR_TraceHullFilter(origin, origin, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);

	// If we appear to be "stuck" after teleporting (likely because the teleport destination
	// was exactly on the ground), set velocity directly to avoid side-effects of
	// TeleportEntity that can cause the player to really get stuck in the ground.
	// This might only be an issue in CSS, but do it on CSGO too just to be safe.
	bool dontUseTeleportEntity = TR_DidHit();

	DebugMsg(client, "DO FIX: Telehop%s", dontUseTeleportEntity ? " (no TeleportEntity)" : "");

	SetVelocity(client, newVelocity, dontUseTeleportEntity);

	return true;
}

// PostThink works a little better than a ProcessMovement post hook because we need to wait for ProcessImpacts (trigger activation)
public void Hook_PlayerPostThink(int client)
{
	if (!IsPlayerAlive(client)) return;
	if (GetEntityMoveType(client) != MOVETYPE_WALK) return;
	if (CheckWater(client)) return;

	bool landed = GetEntPropEnt(client, Prop_Data, "m_hGroundEntity") != -1 && g_iLastGroundEnt[client] == -1;

	float origin[3], landingMins[3], landingMaxs[3], nrm[3], landingPoint[3];

	// Get info about the ground we landed on (if we need to do landing fixes).
	if (landed && (g_cvTriggerjump.BoolValue || g_cvDownhill.BoolValue || g_cvUphill.IntValue == UPHILL_LOSS))
	{
		GetEntPropVector(client, Prop_Data, "m_vecAbsOrigin", origin);

		GetEntPropVector(client, Prop_Data, "m_vecMins", landingMins);
		GetEntPropVector(client, Prop_Data, "m_vecMaxs", landingMaxs);

		float originBelow[3];
		originBelow[0] = origin[0];
		originBelow[1] = origin[1];
		originBelow[2] = origin[2] - LAND_HEIGHT;

		TR_TraceHullFilter(origin, originBelow, landingMins, landingMaxs, MASK_PLAYERSOLID, PlayerFilter);

		if (!TR_DidHit())
		{
			// This should never happen, since we know we are on the ground.
			landed = false;
		}
		else
		{
			TR_GetPlaneNormal(null, nrm);

			if (nrm[2] < MIN_STANDABLE_ZNRM)
			{
				// This is rare, and how the incline fix should behave isn't entirely clear because maybe we should
				// collide with multiple faces at once in this case, but let's just get the ground we officially
				// landed on and use that for our ground normal.

				// landingMins and landingMaxs will contain the final values used to find the ground after returning.
				if (TracePlayerBBoxForGround(origin, originBelow, landingMins, landingMaxs))
				{
					TR_GetPlaneNormal(null, nrm);
				}
				else
				{
					// This should also never happen.
					landed = false;
				}

				DebugMsg(client, "Used bounding box quadrant to find ground (z-normal: %.3f)", nrm[2]);
			}

			TR_GetEndPosition(landingPoint);
		}
	}

	if (landed && TR_GetFraction() > 0.0)
	{
		DoTriggerjumpFix(client, landingPoint, landingMins, landingMaxs);

		// Check if a trigger we just touched put us in the air (probably due to a teleport).
		if (GetEntityFlags(client) & FL_ONGROUND == 0) landed = false;
	}

	// The stair sliding fix changes the outcome of this tick more significantly, so it doesn't really make sense to do incline fixes too.
	if (DoStairsFix(client)) return;

	if (landed)
	{
		DoInclineCollisionFixes(client, nrm);
	}

	DoTelehopFix(client);
}

public bool AddTrigger(int entity, ArrayList triggers)
{
	TR_ClipCurrentRayToEntity(MASK_ALL, entity);
	if (TR_DidHit()) triggers.Push(entity);

	return true;
}

bool TracePlayerBBoxForGround(const float origin[3], const float originBelow[3], float mins[3], float maxs[3])
{
	// See CGameMovement::TracePlayerBBoxForGround()

	float origMins[3], origMaxs[3];
	origMins = mins;
	origMaxs = maxs;

	float nrm[3];

	mins = origMins;

	// -x -y
	maxs[0] = origMaxs[0] > 0.0 ? 0.0 : origMaxs[0];
	maxs[1] = origMaxs[1] > 0.0 ? 0.0 : origMaxs[1];
	maxs[2] = origMaxs[2];

	TR_TraceHullFilter(origin, originBelow, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);

	if (TR_DidHit())
	{
		TR_GetPlaneNormal(null, nrm);
		if (nrm[2] >= MIN_STANDABLE_ZNRM) return true;
	}

	// +x +y
	mins[0] = origMins[0] < 0.0 ? 0.0 : origMins[0];
	mins[1] = origMins[1] < 0.0 ? 0.0 : origMins[1];
	mins[2] = origMins[2];

	maxs = origMaxs;

	TR_TraceHullFilter(origin, originBelow, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);

	if (TR_DidHit())
	{
		TR_GetPlaneNormal(null, nrm);
		if (nrm[2] >= MIN_STANDABLE_ZNRM) return true;
	}

	// -x +y
	mins[0] = origMins[0];
	mins[1] = origMins[1] < 0.0 ? 0.0 : origMins[1];
	mins[2] = origMins[2];

	maxs[0] = origMaxs[0] > 0.0 ? 0.0 : origMaxs[0];
	maxs[1] = origMaxs[1];
	maxs[2] = origMaxs[2];

	TR_TraceHullFilter(origin, originBelow, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);

	if (TR_DidHit())
	{
		TR_GetPlaneNormal(null, nrm);
		if (nrm[2] >= MIN_STANDABLE_ZNRM) return true;
	}

	// +x -y
	mins[0] = origMins[0] < 0.0 ? 0.0 : origMins[0];
	mins[1] = origMins[1];
	mins[2] = origMins[2];

	maxs[0] = origMaxs[0];
	maxs[1] = origMaxs[1] > 0.0 ? 0.0 : origMaxs[1];
	maxs[2] = origMaxs[2];

	TR_TraceHullFilter(origin, originBelow, mins, maxs, MASK_PLAYERSOLID, PlayerFilter);

	if (TR_DidHit())
	{
		TR_GetPlaneNormal(null, nrm);
		if (nrm[2] >= MIN_STANDABLE_ZNRM) return true;
	}

	return false;
}
