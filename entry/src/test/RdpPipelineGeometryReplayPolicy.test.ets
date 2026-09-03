import { describe, it, expect } from '@ohos/hypium';
import {
  replayRdpRendererGeometryAfterPipelineBinding
} from '../main/ets/services/RdpPipelineGeometryReplayPolicy';

export default function rdpPipelineGeometryReplayPolicyTest(): void {
  describe('RdpPipelineGeometryReplayPolicy', (): void => {
    it('replays_native_geometry_after_every_successful_pipeline_binding', 0,
      (): void => {
        let calls: number = 0;
        let observedSessionId: number = 0;
        const synchronize = (sessionId: number): boolean => {
          calls += 1;
          observedSessionId = sessionId;
          return true;
        };

        expect(replayRdpRendererGeometryAfterPipelineBinding(
          true, 41, synchronize)).assertTrue();
        expect(calls).assertEqual(1);
        expect(observedSessionId).assertEqual(41);

        expect(replayRdpRendererGeometryAfterPipelineBinding(
          false, 41, synchronize)).assertFalse();
        expect(replayRdpRendererGeometryAfterPipelineBinding(
          true, 0, synchronize)).assertFalse();
        expect(calls).assertEqual(1);
      });
  });
}
