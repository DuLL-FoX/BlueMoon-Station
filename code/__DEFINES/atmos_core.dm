// Minimum heat capacity threshold — used across atmos system
// Moved here from gas_mixture.dm so it's available to all atmos files
#define MINIMUM_HEAT_CAPACITY	0.0003
#define MINIMUM_MOLE_COUNT		0.01

// Core gas index defines for pure DM atmosphere system
// These provide O(1) numeric-index access into flat lists instead of O(n) associative key lookups

// Core gas indices — the 10 most common gases get fixed positions in core_moles list
#define GAS_IDX_O2       1
#define GAS_IDX_N2       2
#define GAS_IDX_CO2      3
#define GAS_IDX_PLASMA   4
#define GAS_IDX_N2O      5
#define GAS_IDX_H2O      6
#define GAS_IDX_BZ       7
#define GAS_IDX_TRITIUM  8
#define GAS_IDX_MIASMA   9
#define GAS_IDX_FLUORINE 10
#define CORE_GAS_COUNT   10

// Gas mixture object pool sizing
#define GASMIX_POOL_MAX          2000
#define GASMIX_POOL_PREALLOCATE  500

// Translation tables: populated once at init by /datum/auxgm/New()
// gas string ID -> core index (e.g. "o2" -> 1), null if not a core gas
GLOBAL_LIST_INIT(gas_id_to_idx, list())
// core index -> gas string ID (e.g. 1 -> "o2")
GLOBAL_LIST_INIT(gas_idx_to_id, list())
// core index -> specific heat value (e.g. 1 -> 20)
GLOBAL_LIST_INIT(gas_idx_to_specific_heat, list())

// Initializes the gas index translation tables from the gas data singleton.
// Idempotent — safe to call multiple times.
/proc/init_gas_index_tables(datum/auxgm/override)
	// Map core gas string IDs to their fixed indices
	var/static/list/core_gas_ids = list(GAS_O2, GAS_N2, GAS_CO2, GAS_PLASMA, GAS_NITROUS, GAS_H2O, GAS_BZ, GAS_TRITIUM, GAS_MIASMA, GAS_FLUORINE)

	// Clear and rebuild
	GLOB.gas_id_to_idx.Cut()
	GLOB.gas_idx_to_id.Cut()
	GLOB.gas_idx_to_specific_heat.Cut()

	for(var/i in 1 to CORE_GAS_COUNT)
		var/gas_id = core_gas_ids[i]
		GLOB.gas_id_to_idx[gas_id] = i
		GLOB.gas_idx_to_id += gas_id

	// Populate specific heats from gas data
	var/datum/auxgm/gd = override || GLOB.gas_data
	for(var/i in 1 to CORE_GAS_COUNT)
		var/gas_id = GLOB.gas_idx_to_id[i]
		GLOB.gas_idx_to_specific_heat += gd.specific_heats[gas_id]

// ============================================================================
// Debug logging for atmos diagnostics
// Toggle at runtime via GLOB.atmos_debug_logging (VV or admin verb)
// All output goes to game.log with "ATMOS_DEBUG:" prefix for easy grep
// ============================================================================
GLOBAL_VAR_INIT(atmos_debug_logging, FALSE)

#define ATMOS_DEBUG_LOG(msg) if(GLOB.atmos_debug_logging) { log_game("ATMOS_DEBUG: [msg]") }

// Macro for creating a zeroed core_moles list
#define NEW_CORE_MOLES list(0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

// Check if a gas_mixture only has O2 and N2 (indices 1-2), with gases 3-10 all zero.
// This is true for ~80% of station turfs and allows skipping 8 gas checks in share()/archive().
#define UPDATE_SIMPLE_AIR(gm) (gm).simple_air = (!(gm).rare_gases && !(gm).core_moles[3] && !(gm).core_moles[4] && !(gm).core_moles[5] && !(gm).core_moles[6] && !(gm).core_moles[7] && !(gm).core_moles[8] && !(gm).core_moles[9] && !(gm).core_moles[10])
