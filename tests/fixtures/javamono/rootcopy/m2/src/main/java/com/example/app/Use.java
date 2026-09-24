package com.example.app;

import com.example.Foo;

/** Neither copy is in m2: REFUSE. */
public class Use {
	public int go() { return new Foo().n(); }
}
