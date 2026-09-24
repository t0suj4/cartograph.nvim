package com.example.app;

import com.example.core.Registry;
import java.util.List;

/**
 * The importer. Two assertions live here:
 *   com.example.core.Registry -> AMBIGUOUS (mod_a and mod_b both hold it),
 *                                and must NOT silently pick one
 *   java.util.List            -> EXTERNAL, must stay frontier and must not
 *                                suffix-match any local file
 */
public class Client {

	public String use(Registry registry, List<String> items) {
		return registry.lookup(items.isEmpty() ? "k" : items.get(0));
	}
}
