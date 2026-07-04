#include "engine.hpp"

namespace OMW {
    void Engine::go()
    {
        run(frames());
    }

    int run(int n)
    {
        return n + 1;
    }

    static int helper_unused()
    {
        return 0;
    }
}

int main()
{
    OMW::Engine e;
    e.go();
    return 0;
}
