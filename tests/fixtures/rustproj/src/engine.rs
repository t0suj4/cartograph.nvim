use crate::helper;

pub struct Engine {
    speed: u32,
}

impl Engine {
    pub fn new(speed: u32) -> Engine {
        Engine { speed }
    }

    pub fn speed(&self) -> u32 {
        self.speed
    }
}

impl std::fmt::Display for Engine {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "{}", self.speed)
    }
}

#[test]
fn spins() {
    let eng = Engine::new(1);
    assert_eq!(eng.speed(), 1);
}

fn lonely() {}
