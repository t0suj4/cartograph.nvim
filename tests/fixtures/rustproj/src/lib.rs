mod engine;

pub use engine::Engine;

pub fn boot() -> Engine {
    let eng = Engine::new(2);
    helper(eng.speed());
    Engine::new(3)
}

fn helper(x: u32) -> u32 {
    x + 1
}
