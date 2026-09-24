package com.x.app;

import com.x.util.Util;

/** Two copies, neither in mod_c: which one it sees is a classpath fact, so this must REFUSE. */
public class UseC {
	public String go() { return Util.id("c"); }
}
