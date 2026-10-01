import { DiagnosticAiProviderProfile, DiagnosticAiSettings, defaultDiagnosticAiSettings } from './DiagnosticAiModels';

export interface DiagnosticAiSettingsSnapshot { profiles: DiagnosticAiProviderProfile[]; settings: DiagnosticAiSettings; }

export function validDiagnosticAiSettings(value: DiagnosticAiSettings): boolean {
  return typeof value.selectedProviderId === 'string' && typeof value.selectedModelId === 'string' &&
    typeof value.showOrbOnHostPage === 'boolean' && typeof value.reducedMotion === 'boolean' &&
    Number.isSafeInteger(value.retentionDays) && value.retentionDays >= 1 && value.retentionDays <= 30;
}

export function cloneDiagnosticAiSettings(value: DiagnosticAiSettings): DiagnosticAiSettings {
  return { selectedProviderId: value.selectedProviderId, selectedModelId: value.selectedModelId,
    showOrbOnHostPage: value.showOrbOnHostPage, reducedMotion: value.reducedMotion, retentionDays: value.retentionDays };
}

export function emptyDiagnosticAiSnapshot(): DiagnosticAiSettingsSnapshot {
  return { profiles: [], settings: defaultDiagnosticAiSettings() };
}
