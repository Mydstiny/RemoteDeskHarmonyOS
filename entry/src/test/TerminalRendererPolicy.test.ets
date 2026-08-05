import { terminalCellIndex, terminalDimensionsMatchSnapshot, terminalGridDimension } from
  '../main/ets/services/TerminalRendererPolicy';

export default function terminalRendererPolicyTest(): void {
  describe('TerminalRendererPolicy', (): void => {
    it('normalizes grid dimensions before comparing a snapshot', 0, (): void => {
      expect(terminalGridDimension(80.9)).assertEqual(80);
      expect(terminalDimensionsMatchSnapshot(80.9, 24.2, 80, 24)).assertTrue();
      expect(terminalDimensionsMatchSnapshot(80, 24, 79, 24)).assertFalse();
    });

    it('rejects cell indices outside the snapshot grid', 0, (): void => {
      expect(terminalCellIndex(3, 2, 1, 2)).assertEqual(5);
      expect(terminalCellIndex(3, 2, 2, 0)).assertEqual(-1);
      expect(terminalCellIndex(3, 2, 0, 3)).assertEqual(-1);
    });
  });
}
