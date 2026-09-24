package com.example.core;

/**
 * CASE 1 -- SAME FULLY-QUALIFIED NAME IN TWO MODULES (mod_b copy). Shading and
 * relocated vendor copies produce this in real trees. An importer of
 * com.example.core.Registry has TWO candidates, so the resolver must REFUSE
 * rather than pick whichever the file walk reached first -- the sound-first
 * rule. A suffix index makes both visible; that is the point of using one.
 */
public class Registry {

	public String lookup(String key) {
		return key;
	}
}
