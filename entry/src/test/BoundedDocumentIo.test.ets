import { describe, it, expect } from '@ohos/hypium';
import {
  documentTransferIsComplete,
  validateBoundedDocumentSize
} from '../main/ets/services/BoundedDocumentIo';

export default function boundedDocumentIoTest(): void {
  describe('BoundedDocumentIo', (): void => {
    it('rejects_empty_and_oversized_documents_before_allocation', 0, (): void => {
      expect(validateBoundedDocumentSize(0, 1024)).assertEqual('empty');
      expect(validateBoundedDocumentSize(1025, 1024)).assertEqual('too_large');
      expect(validateBoundedDocumentSize(1024, 1024)).assertEqual('ok');
    });

    it('requires_exact_transfer_completion', 0, (): void => {
      expect(documentTransferIsComplete(4096, 4095)).assertFalse();
      expect(documentTransferIsComplete(4096, 4096)).assertTrue();
      expect(documentTransferIsComplete(4096, 4097)).assertFalse();
    });
  });
}
