package main

import "example.com/shop/store"

func main() {
	s := store.NewStore(2)
	total := s.Total()
	report(total)
}

func report(n int) int {
	return n + 1
}

func lonely() {}
