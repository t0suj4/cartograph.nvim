package com.example.app;

import com.example.core.Registry;

/**
 * THE BUG (F5). Rooted at multi/, the real path is
 * mod_core/src/main/java/com/example/core/Registry.java. resolve_import tries
 * `com/example/core/Registry.java` and the two `src/{main,test}/java/`
 * prefixes -- none has the module segment, so the import edge is lost.
 */
public class Client {

	public String use(Registry registry) {
		return registry.lookup("k");
	}
}
