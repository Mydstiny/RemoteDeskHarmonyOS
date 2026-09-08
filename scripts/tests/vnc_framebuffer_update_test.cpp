// Production RFB parser + production POSIX transport, fed by socketpair.
#include "vnc/vnc_rfb_engine.h"
#include <sys/socket.h>
#include <unistd.h>
#include <signal.h>
#include <cerrno>
#include <cstdlib>
#include <future>
#include <iostream>
#include <thread>
#include <vector>
#include <zlib.h>

#define CHECK(v) do { if (!(v)) { std::cerr << "FAIL line " << __LINE__ << ": " #v << '\n'; std::abort(); } } while (0)
using Bytes = std::vector<uint8_t>;
void u16(Bytes& b, uint16_t n) { b.push_back(n >> 8); b.push_back(n); }
void u32(Bytes& b, uint32_t n) { u16(b, n >> 16); u16(b, n); }
void header(Bytes& b, uint16_t n) { b.push_back(0); u16(b, n); } // type byte already consumed by receiveLoop
void rectangle(Bytes& b, int32_t encoding, uint16_t x=0, uint16_t y=0, uint16_t w=1, uint16_t h=1) {
    u16(b,x); u16(b,y); u16(b,w); u16(b,h); u32(b,static_cast<uint32_t>(encoding));
}
void raw(Bytes& b, uint8_t blue=0x33, uint16_t x=0) { rectangle(b,0,x); b.insert(b.end(),{blue,0x22,0x11,0}); }
void last(Bytes& b) { rectangle(b,-224,0,0,0,0); }
void zrle(Bytes& b) {
    rectangle(b,16);
    const Bytes plain{1,0x33,0x22,0x11}; // one solid CPIXEL tile
    z_stream s{}; CHECK(deflateInit(&s,Z_DEFAULT_COMPRESSION)==Z_OK);
    Bytes compressed(128); s.next_in=const_cast<Bytef*>(plain.data()); s.avail_in=plain.size();
    s.next_out=compressed.data(); s.avail_out=compressed.size();
    CHECK(deflate(&s,Z_SYNC_FLUSH)==Z_OK); compressed.resize(compressed.size()-s.avail_out);
    deflateEnd(&s); u32(b,compressed.size()); b.insert(b.end(),compressed.begin(),compressed.end());
}
struct Fixture {
    int peer=-1;
    std::thread writer;
    std::vector<Bytes> frames;
    int cursors=0;
    std::shared_ptr<VncRfbEngine> engine;
    explicit Fixture(Bytes bytes, size_t chunk=512) {
        int fd[2]; CHECK(socketpair(AF_UNIX,SOCK_STREAM,0,fd)==0); peer=fd[1];
        ConnectionConfig config{};
        engine=std::make_shared<VncRfbEngine>(config,[this](const VideoFrame& f) {
            frames.emplace_back(f.data,f.data+f.size);
        },nullptr,[this](const VncCursorProtocol::DecodedCursor&) { ++cursors; });
        CHECK(engine->initializeUpdateStreamForTesting(fd[0],2,1));
        writer=std::thread([this,bytes=std::move(bytes),chunk] {
            size_t offset=0;
            while(offset<bytes.size()) {
                const ssize_t n=send(peer,bytes.data()+offset,std::min(chunk,bytes.size()-offset),0);
                if(n<0 && errno==EINTR) continue;
                if(n<=0) break;
                offset+=static_cast<size_t>(n);
            }
            shutdown(peer,SHUT_WR);
        });
    }
    ~Fixture() { engine.reset(); if(writer.joinable()) writer.join(); close(peer); }
    bool receive(std::string& error, bool& pipeline) { return engine->receiveUpdateForTesting(pipeline,error); }
    void good(size_t frameCount, bool expectedPipeline=false) {
        std::string error; bool pipeline=false; CHECK(receive(error,pipeline)); CHECK(error.empty());
        CHECK(pipeline==expectedPipeline); CHECK(frames.size()==frameCount);
    }
    void bad(const std::string& marker) {
        std::string error; bool pipeline=false; CHECK(!receive(error,pipeline));
        CHECK(error.find(marker)!=std::string::npos); CHECK(frames.empty());
    }
};
int cases=0;
template<class F> void test(const char* name,F f) { f(); ++cases; std::cout << "PASS " << name << '\n'; }
int main() {
    signal(SIGPIPE,SIG_IGN);
    test("empty fixed update",[]{ Bytes b; header(b,0); Fixture f(b); f.good(0); });
    test("single raw fixed update",[]{ Bytes b; header(b,1); raw(b); Fixture f(b); f.good(1); CHECK(f.frames[0][0]==0x33); });
    test("multi rectangle presents once",[]{ Bytes b; header(b,2); raw(b); raw(b,0x55,1); Fixture f(b); f.good(1); CHECK(f.frames[0][4]==0x55); });
    test("65535 immediate LastRect",[]{ Bytes b; header(b,65535); last(b); Fixture f(b); f.good(0); });
    test("65535 raw LastRect then next update stays aligned",[]{
        Bytes b; header(b,65535); raw(b); last(b); header(b,1); raw(b,0x77);
        Fixture f(b,1); f.good(1); f.good(2); CHECK(f.frames[1][0]==0x77);
    });
    test("non-sentinel upper bound also accepts LastRect",[]{ Bytes b; header(b,4097); raw(b); last(b); Fixture f(b); f.good(1); });
    test("LastRect at exact actual limit",[]{ Bytes b; header(b,65535); for(int i=0;i<4096;i++) raw(b); last(b); Fixture f(b); f.good(1); });
    test("fixed update at exact limit without terminator",[]{ Bytes b; header(b,4096); for(int i=0;i<4096;i++) raw(b); Fixture f(b); f.good(1); });
    test("65535 actual overflow rejected before payload",[]{ Bytes b; header(b,65535); for(int i=0;i<4096;i++) raw(b); rectangle(b,0); Fixture f(b); f.bad("[VNC-FBU reason=1 advertised=65535 processed=4096 encoding=0]"); });
    test("fixed actual overflow rejected before payload",[]{ Bytes b; header(b,4097); for(int i=0;i<4096;i++) raw(b); rectangle(b,0); Fixture f(b); f.bad("[VNC-FBU reason=1 advertised=4097 processed=4096 encoding=0]"); });
    test("pseudo rectangles count against budget",[]{ Bytes b; header(b,65535); for(int i=0;i<4097;i++) rectangle(b,-239,0,0,0,0); Fixture f(b); f.bad("[VNC-FBU reason=1 advertised=65535 processed=4096 encoding=-239]"); CHECK(f.cursors==4096); });
    test("missing LastRect does not present partial update",[]{ Bytes b; header(b,65535); raw(b); Fixture f(b); f.bad("[VNC-FBU reason=2 advertised=65535 processed=1 encoding=0]"); });
    test("truncated rectangle header",[]{ Bytes b; header(b,65535); b.push_back(0); Fixture f(b); f.bad("[VNC-FBU reason=2 advertised=65535 processed=0 encoding=0]"); });
    test("truncated raw payload",[]{ Bytes b; header(b,65535); rectangle(b,0); b.push_back(0); Fixture f(b); f.bad("[VNC-FBU reason=3 advertised=65535 processed=0 encoding=0]"); });
    test("raw bounds retained",[]{ Bytes b; header(b,65535); raw(b,0x33,2); last(b); Fixture f(b); f.bad("VNC Raw rectangle is outside the framebuffer"); });
    test("unknown encoding retained",[]{ Bytes b; header(b,65535); rectangle(b,12345); Fixture f(b); f.bad("[VNC-FBU reason=4 advertised=65535 processed=0 encoding=12345]"); });
    test("CopyRect cursor resize and LastRect",[]{
        Bytes b; header(b,65535); raw(b); rectangle(b,1,1); u16(b,0); u16(b,0);
        rectangle(b,-239,0,0,0,0); rectangle(b,-223,0,0,2,1); last(b);
        Fixture f(b); f.good(1); CHECK(f.cursors==1);
    });
    test("ZRLE in LastRect update does not pipeline early",[]{ Bytes b; header(b,65535); zrle(b); last(b); Fixture f(b); f.good(1); CHECK(f.frames[0][0]==0x33); });
    test("single ZRLE retains next-request pipeline",[]{ Bytes b; header(b,1); zrle(b); Fixture f(b); f.good(1,true); });
    test("ZRLE compressed bound retained",[]{ Bytes b; header(b,65535); rectangle(b,16); u32(b,0xffffffff); Fixture f(b); f.bad("VNC ZRLE compressed length exceeds the rectangle-safe limit"); });
    test("ERROR message published before delayed external callback",[]{
        std::promise<void> entered, release;
        auto enteredFuture=entered.get_future(); auto releaseFuture=release.get_future();
        ConnectionConfig config{};
        auto engine=std::make_shared<VncRfbEngine>(config,nullptr,
            [&](ConnectionState state,const std::string&) {
                if(state==ConnectionState::ERROR) { entered.set_value(); releaseFuture.wait(); }
            },nullptr);
        const std::string message="VNC update contains too many rectangles [VNC-FBU reason=1 advertised=65535 processed=4096 encoding=0]";
        std::thread worker([&] { engine->emitStateForTesting(ConnectionState::ERROR,message); });
        CHECK(enteredFuture.wait_for(std::chrono::seconds(2))==std::future_status::ready);
        CHECK(engine->state()==ConnectionState::ERROR);
        CHECK(engine->lastStateMessage()==message);
        release.set_value(); worker.join();
    });
    test("state callback can reenter without stale message overwrite",[]{
        ConnectionConfig config{}; std::shared_ptr<VncRfbEngine> engine;
        engine=std::make_shared<VncRfbEngine>(config,nullptr,
            [&](ConnectionState state,const std::string&) {
                CHECK(!engine->lastStateMessage().empty());
                if(state==ConnectionState::ERROR) engine->emitStateForTesting(ConnectionState::DISCONNECTED,"cancelled");
            },nullptr);
        engine->emitStateForTesting(ConnectionState::ERROR,"error");
        CHECK(engine->state()==ConnectionState::DISCONNECTED); CHECK(engine->lastStateMessage()=="cancelled");
    });
    std::cout << cases << " native VNC update checks passed\n";
}
