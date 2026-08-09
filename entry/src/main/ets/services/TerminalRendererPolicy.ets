/**
 * Small pure policies shared by the native terminal renderer and its tests.
 */

export function terminalGridDimension(value: number): number {
  return Math.max(1, Math.floor(value));
}

export function terminalDimensionsMatchSnapshot(
  activeCols: number,
  activeRows: number,
  snapshotCols: number,
  snapshotRows: number
): boolean {
  return terminalGridDimension(activeCols) === snapshotCols &&
    terminalGridDimension(activeRows) === snapshotRows;
}

export function terminalCellIndex(
  cols: number,
  rows: number,
  row: number,
  col: number
): number {
  const safeCols: number = terminalGridDimension(cols);
  const safeRows: number = terminalGridDimension(rows);
  if (row < 0 || row >= safeRows || col < 0 || col >= safeCols) {
    return -1;
  }
  return row * safeCols + col;
}
