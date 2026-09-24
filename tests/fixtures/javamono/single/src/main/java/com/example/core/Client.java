package com.example.core;

import com.example.core.Registry;

/** CONTROL: rooted at single/, the import path matches src/main/java/. */
public class Client {

	public String use(Registry registry) {
		return registry.lookup("k");
	}
}
