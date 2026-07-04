package store

type Store struct {
	total int
}

func NewStore(n int) *Store {
	return &Store{total: n}
}

func (s *Store) Total() int {
	return s.total
}

func init() {
	register()
}

func register() {}
