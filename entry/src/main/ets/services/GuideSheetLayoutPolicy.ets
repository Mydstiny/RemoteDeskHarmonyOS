export interface OperationGuideSheetLayout {
  height: number;
  compact: boolean;
  availableHeight: number;
  lessonViewportHeight: number;
}

function finitePositive(value: number, fallback: number): number {
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function nonNegativeInteger(value: number): number {
  return Number.isSafeInteger(value) && value > 0 ? value : 0;
}

/**
 * Keeps the operation-guide Sheet content-sized on tall windows while
 * reserving a usable, independently scrollable lesson viewport on short ones.
 */
export function resolveOperationGuideSheetLayout(viewportHeight: number,
  breakpoint: string, lessonCount: number, expandedStepCount: number,
  expandedHasNote: boolean, measuredLessonHeight: number = 0): OperationGuideSheetLayout {
  const small: boolean = breakpoint === 'sm';
  const extraLarge: boolean = breakpoint === 'xl';
  const fallbackViewport: number = small ? 720 : 840;
  const normalizedViewport: number = finitePositive(viewportHeight, fallbackViewport);
  const viewportInset: number = small ? 16 : 32;
  const availableHeight: number = Math.max(320, normalizedViewport - viewportInset);
  const compact: boolean = availableHeight < 620;
  const chromeHeight: number = compact ? 300 : 350;
  const normalizedLessonCount: number = nonNegativeInteger(lessonCount);
  const normalizedStepCount: number = nonNegativeInteger(expandedStepCount);
  const estimatedLessonHeight: number = normalizedLessonCount * 74 +
    (normalizedStepCount > 0 ? 22 + normalizedStepCount * 32 +
      (expandedHasNote ? 64 : 0) : 0);
  const lessonHeight: number = finitePositive(measuredLessonHeight, estimatedLessonHeight);
  const minimumHeight: number = compact ? 420 : 500;
  const preferredMaximum: number = small ? 680 : (extraLarge ? 780 : 720);
  const naturalHeight: number = chromeHeight + lessonHeight;
  const height: number = Math.round(Math.min(availableHeight, preferredMaximum,
    Math.max(minimumHeight, naturalHeight)));
  return {
    height,
    compact,
    availableHeight,
    lessonViewportHeight: Math.max(96, height - chromeHeight)
  };
}
