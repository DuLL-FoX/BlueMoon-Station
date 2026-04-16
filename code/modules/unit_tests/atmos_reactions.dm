/// Unit tests for the atmospheric reaction system.
/// Verifies reaction registration, empty-mixture safety, and threshold behavior.

// ===== Reaction System Registration =====

/datum/unit_test/reaction_system

/datum/unit_test/reaction_system/Run()
	// Verify SSair.gas_reactions is populated
	TEST_ASSERT_NOTNULL(SSair.gas_reactions, "SSair.gas_reactions should not be null")
	TEST_ASSERT(length(SSair.gas_reactions) > 0, "SSair.gas_reactions should contain at least one reaction")

	// Verify each registered reaction has min_requirements defined
	for(var/datum/gas_reaction/reaction as anything in SSair.gas_reactions)
		TEST_ASSERT_NOTNULL(reaction.min_requirements, "Reaction [reaction.type] should have min_requirements defined")
		TEST_ASSERT(length(reaction.min_requirements) > 0, "Reaction [reaction.type] min_requirements should not be empty")

// ===== No Reaction on Empty Mixture =====

/datum/unit_test/no_reaction_on_empty

/datum/unit_test/no_reaction_on_empty/Run()
	var/datum/gas_mixture/gm = new(CELL_VOLUME)
	// Leave mixture completely empty (no gases, default temperature)

	var/result = gm.react()
	// Should return NO_REACTION (0) since there's nothing to react
	TEST_ASSERT(!result || result == NO_REACTION, "Empty gas_mixture react() should return NO_REACTION, got [result]")

	qdel(gm)

// ===== No Reaction Below Threshold =====

/datum/unit_test/no_reaction_below_threshold

/datum/unit_test/no_reaction_below_threshold/Run()
	var/datum/gas_mixture/gm = new(CELL_VOLUME)

	// Standard atmosphere: O2 + N2 at room temperature
	// This should not trigger any reactions
	gm.set_moles(GAS_O2, MOLES_O2STANDARD)
	gm.set_moles(GAS_N2, MOLES_N2STANDARD)
	gm.set_temperature(T20C)

	var/result = gm.react()
	TEST_ASSERT(!result || result == NO_REACTION, "Standard O2+N2 at room temperature should not react, got [result]")

	qdel(gm)
