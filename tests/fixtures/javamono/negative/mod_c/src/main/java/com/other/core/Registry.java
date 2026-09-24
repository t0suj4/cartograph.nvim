package com.other.core;

/**
 * CASE 2 -- SUFFIX COLLISION, DIFFERENT PACKAGE. The path tail
 * `core/Registry.java` is shared with com.example.core.Registry, but the
 * package is com.other.core, so it is NOT the imported class.
 *
 * The current algorithm is safe here by accident: it does exact path lookups
 * on progressively shorter dotted-name suffixes, so `core/Registry.java` never
 * matches this file's full path. A suffix INDEX -- the cheaper fix proposed for
 * F5 -- would match it. This is that fix's regression test: the index must
 * compare the whole package path, not a tail.
 */
public class Registry {

	public String lookup(String key) {
		return key;
	}
}
