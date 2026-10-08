#!/usr/bin/env python3
"""Run the production coherent snapshot methods without an EGL device.

Also verify that the three native presentation paths publish success only after
eglSwapBuffers succeeds. The test does not claim that a device displayed pixels.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import os

root = Path(__file__).resolve().parents[2]
source = (root / 'entry/src/main/cpp/render/gl_renderer.cpp').read_text()
header = (root / 'entry/src/main/cpp/render/gl_renderer.h').read_text()


def method(signature):
    start = source.index(signature)
    cursor = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[cursor] == '{') - (source[cursor] == '}')
        cursor += 1
    return source[start:cursor]


success = '''const bool swapped = eglSwapBuffers(eglDisplay_, eglSurface_) == EGL_TRUE;
    if (swapped) {
        PublishViewportSnapshot(lastVpX_, lastVpY_, lastVpW_, lastVpH_, true);
    }'''
for name in ['RdpPresentMetrics GLRenderer::RenderRawBGRAInternal(',
             'RdpPresentMetrics GLRenderer::PresentFrame(',
             'RdpPresentMetrics GLRenderer::RenderRetainedFrameLocked(']:
    assert method(name).count(success) == 1, name
assert source.count('PublishViewportSnapshot(lastVpX_, lastVpY_, lastVpW_, lastVpH_, true)') == 3
assert 'snapshotPresentedTransformVersion_(0)' in source
assert source.count('snapshotPresentedTransformVersion_.store(') == 1
fields = re.findall(r'^    (std::atomic<[^>]+> (?:viewportSnapshotVersion_|snapshot\w+_));$', header, re.M)
assert len(fields) >= 14
declarations = '\n'.join('    ' + field + '{0};' for field in fields)
program = '''#include <atomic>
#include <algorithm>
#include <cmath>
#include <mutex>
#include <cassert>
#include <cstdint>
#include <thread>
#include <iostream>
#define OH_LOG_WARN(...) ((void)0)
static constexpr double kMaxCanvasScale = 12.0;
struct RendererCanvasTransformSnapshot {
    uint64_t version = 0;
    int rotationQuarterTurns = 0;
    bool flipX = false, flipY = false, valid = false;
};
class GLRenderer {
public:
    int sourceWidth_ = 1920, sourceHeight_ = 1080, width_ = 1280, height_ = 720;
    uint64_t appliedCanvasTransformVersion_ = 4;
    int canvasRotationQuarterTurns_ = 0;
    bool canvasFlipX_ = false, canvasFlipY_ = false;
    double canvasScale_ = 1.0, canvasPanX_ = 0, canvasPanY_ = 0;
    std::mutex transformPublishMutex_;
    std::atomic<uint64_t> canvasTransformVersion_{0};
    std::atomic<double> pendingCanvasScale_{1}, pendingCanvasPanX_{0}, pendingCanvasPanY_{0};
    std::atomic<int> pendingCanvasRotationQuarterTurns_{0};
    std::atomic<bool> pendingCanvasFlipX_{false}, pendingCanvasFlipY_{false};
    void RequestRedraw() {}
    uint64_t SetCanvasTransform(double, double, double, int, bool, bool);
    void ApplyPendingCanvasTransformLocked();
    RendererCanvasTransformSnapshot GetCanvasTransformSnapshot() const;
    void GetViewportSnapshot(int&, int&, int&, int&, int&, int&, int&, int&, uint64_t&, uint64_t* = nullptr) const;
    void PublishViewportSnapshot(int, int, int, int, bool = false);
''' + declarations + '\n};\n'
program += method('void GLRenderer::GetViewportSnapshot(') + '\n'
program += method('void GLRenderer::PublishViewportSnapshot(') + '\n'
program += method('uint64_t GLRenderer::SetCanvasTransform(') + '\n'
program += method('void GLRenderer::ApplyPendingCanvasTransformLocked(') + '\n'
program += method('RendererCanvasTransformSnapshot GLRenderer::GetCanvasTransformSnapshot(') + '\n'
program += r'''
struct Snapshot { int x=0,y=0,w=0,h=0,srcw=0,srch=0,surfw=0,surfh=0; uint64_t version=0,presented=0; };
Snapshot read(const GLRenderer& r) {
    Snapshot s; r.GetViewportSnapshot(s.x,s.y,s.w,s.h,s.srcw,s.srch,s.surfw,s.surfh,s.version,&s.presented); return s;
}
int main() {
    GLRenderer r;
    assert(read(r).presented == 0);
    r.PublishViewportSnapshot(0,0,1280,720);
    assert(read(r).version == 4 && read(r).presented == 0);
    r.PublishViewportSnapshot(0,0,1280,720,true);
    assert(read(r).presented == 4);
    r.PublishViewportSnapshot(0,0,1280,720); // Same geometry remains a previously presented view.
    assert(read(r).presented == 4);
    r.appliedCanvasTransformVersion_ = 5;
    r.PublishViewportSnapshot(0,0,1280,720);
    assert(read(r).presented == 0); // A failed swap cannot advance it.
    r.PublishViewportSnapshot(0,0,1280,720,true);
    assert(read(r).presented == 5);
    r.width_ = 640; r.height_ = 360;
    r.PublishViewportSnapshot(0,0,640,360);
    assert(read(r).presented == 0); // Resize at the same transform version invalidates it.
    r.PublishViewportSnapshot(0,0,640,360,true);
    assert(read(r).presented == 5);
    r.sourceWidth_ = 3840;
    r.PublishViewportSnapshot(0,0,640,360);
    assert(read(r).presented == 0);
    r.PublishViewportSnapshot(0,0,640,360,true);
    r.PublishViewportSnapshot(20,0,640,360);
    assert(read(r).presented == 0);
    r.PublishViewportSnapshot(20,0,640,360,true);
    r.canvasRotationQuarterTurns_ = 1;
    r.PublishViewportSnapshot(20,0,640,360);
    assert(read(r).presented == 0);
    r.PublishViewportSnapshot(20,0,640,360,true);
    r.canvasFlipX_ = true;
    r.PublishViewportSnapshot(20,0,640,360);
    assert(read(r).presented == 0);
    r.PublishViewportSnapshot(20,0,640,360,true);
    r.canvasFlipY_ = true;
    r.PublishViewportSnapshot(20,0,640,360);
    assert(read(r).presented == 0);
    Snapshot old;
    r.GetViewportSnapshot(old.x,old.y,old.w,old.h,old.srcw,old.srch,old.surfw,old.surfh,old.version);
    assert(old.version == 5); // Existing readers need no new argument.
    GLRenderer concurrent;
    std::atomic<bool> done{false};
    std::thread writer([&] {
        for (uint64_t n=1;n<=200000;n++) {
            concurrent.appliedCanvasTransformVersion_=n;
            concurrent.width_=100+int(n%1000); concurrent.height_=concurrent.width_*2;
            concurrent.sourceWidth_=1000+int(n); concurrent.sourceHeight_=2000+int(n);
            concurrent.PublishViewportSnapshot(0,0,concurrent.width_,concurrent.height_);
            concurrent.PublishViewportSnapshot(0,0,concurrent.width_,concurrent.height_,true);
        }
        done.store(true,std::memory_order_release);
    });
    uint64_t observations=0;
    do {
        const auto s=read(concurrent);
        if (s.version != 0) {
            assert(s.presented==0 || s.presented==s.version);
            assert(s.srcw==1000+int(s.version) && s.srch==2000+int(s.version));
            assert(s.surfw==100+int(s.version%1000) && s.surfh==s.surfw*2);
            assert(s.w==s.surfw && s.h==s.surfh);
            observations++;
        }
    } while (!done.load(std::memory_order_acquire));
    writer.join(); assert(read(concurrent).presented==200000);
    // Exercise both production publication stages: UI pending tuple -> EGL
    // owner -> lock-free viewport/canvas readers. Host stress supplements the
    // C++ memory-order review; passing it does not prove weak-memory safety.
    GLRenderer pipeline;
    pipeline.appliedCanvasTransformVersion_ = 0;
    std::atomic<bool> submitted{false}, rendered{false};
    std::thread submitter([&] {
        for (uint64_t n=1; n<=200000; n++) {
            assert(pipeline.SetCanvasTransform(1+double(n%10), double(n), -double(n),
                int(n%4), (n&1)!=0, (n&2)!=0)==2*n);
        }
        submitted.store(true,std::memory_order_release);
    });
    std::thread presenter([&] {
        do {
            pipeline.ApplyPendingCanvasTransformLocked();
            const uint64_t version=pipeline.appliedCanvasTransformVersion_;
            if (version==0) continue;
            const uint64_t n=version/2;
            assert(version%2==0);
            assert(pipeline.canvasScale_==1+double(n%10));
            assert(pipeline.canvasPanX_==double(n) && pipeline.canvasPanY_==-double(n));
            assert(pipeline.canvasRotationQuarterTurns_==int(n%4));
            assert(pipeline.canvasFlipX_==((n&1)!=0) && pipeline.canvasFlipY_==((n&2)!=0));
            pipeline.PublishViewportSnapshot(0,0,1280,720,true);
        } while (!submitted.load(std::memory_order_acquire) ||
                 pipeline.appliedCanvasTransformVersion_!=400000);
        rendered.store(true,std::memory_order_release);
    });
    uint64_t pipelineObservations=0;
    do {
        const auto transform=pipeline.GetCanvasTransformSnapshot();
        if (transform.valid) {
            const uint64_t n=transform.version/2;
            assert(transform.version%2==0);
            assert(transform.rotationQuarterTurns==int(n%4));
            assert(transform.flipX==((n&1)!=0) && transform.flipY==((n&2)!=0));
            pipelineObservations++;
        }
        const auto viewport=read(pipeline);
        assert(viewport.version==viewport.presented);
    } while (!rendered.load(std::memory_order_acquire));
    submitter.join(); presenter.join();
    assert(read(pipeline).presented==400000);
    std::cout << "PASS production pending/apply/presented/canvas pipeline; observations=" << pipelineObservations << '\n';
    std::cout << "PASS production snapshot success/failed swap, geometry invalidation, legacy reader and coherent concurrent reads; observations=" << observations << '\n';
}
'''
with tempfile.TemporaryDirectory(prefix='pro-presented-transform-') as directory:
    cpp = Path(directory) / 'snapshot.cpp'
    binary = Path(directory) / 'snapshot'
    cpp.write_text(program)
    if os.environ.get('PRO_RENDERER_HARNESS_OUTPUT'):
        Path(os.environ['PRO_RENDERER_HARNESS_OUTPUT']).write_text(program)
    subprocess.run(['c++', '-std=c++17', '-O2', '-pthread', str(cpp), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print('PASS actual RAW/OES/retained swap-success publication boundaries')
