export type CloudMetadataReadState =
  'present' | 'absent' | 'error';

export interface CloudMetadataReadResult {
  state: CloudMetadataReadState;
  value: string;
}

export type CloudMetadataQuery =
  () => string | null;

/**
 * Metadata absence is a security decision. A query failure must remain
 * distinguishable from a proven missing row so barriers and checkpoints
 * cannot fail open.
 */
export function readCloudMetadataState(
  query: CloudMetadataQuery
): CloudMetadataReadResult {
  try {
    const value: string | null = query();
    if (value === null) {
      return { state: 'absent', value: '' };
    }
    return { state: 'present', value };
  } catch (_error) {
    return { state: 'error', value: '' };
  }
}

export function cloudMetadataAbsentProven(
  result: CloudMetadataReadResult
): boolean {
  return result.state === 'absent';
}

export function cloudMetadataBoundaryReadable(
  result: CloudMetadataReadResult
): boolean {
  return result.state !== 'error';
}

export function cloudMetadataCheckpointBlocks(
  result: CloudMetadataReadResult
): boolean {
  return result.state !== 'absent';
}
