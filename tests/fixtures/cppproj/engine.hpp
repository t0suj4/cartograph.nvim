namespace OMW {
    class Engine {
    public:
        void go();
        int frames() const { return mFrames; }
    private:
        int mFrames = 0;
    };
    int run(int n);
}
