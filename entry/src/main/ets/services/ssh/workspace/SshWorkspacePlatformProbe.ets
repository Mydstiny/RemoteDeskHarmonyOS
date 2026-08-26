/**
 * Runtime facts for the SSH workspace capability gate.
 *
 * The probe only reads stable BasicServicesKit device metadata.  New ArkUI
 * declarations are supplied explicitly by the build/SDK adapter instead of
 * being guessed from a numeric API level.  Until an adapter proves a
 * declaration, every new renderer remains fail-closed and the existing
 * static layout is selected.
 */
import { deviceInfo } from '@kit.BasicServicesKit';
import {
  defaultSshWorkspacePlatformFacts,
  SshWorkspacePlatformFacts
} from './SshWorkspaceCapabilityPolicy';

export interface SshWorkspacePlatformDeclarations {
  dynamicLayoutDeclared: boolean;
  containerReaderDeclared: boolean;
  uiDesignKitDeclared: boolean;
  multiWindowDeclared: boolean;
  keyboardShortcutDeclared: boolean;
  highContrast: boolean;
  reduceMotion: boolean;
  lowPowerMode: boolean;
  terminalHighOutput: boolean;
}

export function defaultSshWorkspacePlatformDeclarations(): SshWorkspacePlatformDeclarations {
  return {
    // These are intentionally false until the corresponding SDK declaration
    // and target-device capability are recorded in the API26 adapter.
    dynamicLayoutDeclared: false,
    containerReaderDeclared: false,
    uiDesignKitDeclared: false,
    multiWindowDeclared: false,
    keyboardShortcutDeclared: true,
    highContrast: false,
    reduceMotion: false,
    lowPowerMode: false,
    terminalHighOutput: false
  };
}

/**
 * Read the runtime API level and merge only explicitly proven declarations.
 * The declaration object is kept separate so a future API26 adapter can be
 * swapped in without changing SSH page code or the authentication path.
 */
export function probeSshWorkspacePlatformFacts(featureFlagEnabled: boolean,
  declarations: SshWorkspacePlatformDeclarations =
    defaultSshWorkspacePlatformDeclarations()): SshWorkspacePlatformFacts {
  const facts: SshWorkspacePlatformFacts = defaultSshWorkspacePlatformFacts();
  facts.featureFlagEnabled = featureFlagEnabled === true;
  try {
    const sdkApiVersion: number = Number(deviceInfo.sdkApiVersion);
    if (Number.isFinite(sdkApiVersion) && sdkApiVersion > 0) {
      facts.apiVersion = Math.max(1, Math.floor(sdkApiVersion));
    }
  } catch (_err) {
    // Keep the conservative API23 baseline if device metadata is unavailable.
  }
  facts.dynamicLayoutDeclared = declarations.dynamicLayoutDeclared === true;
  facts.containerReaderDeclared = declarations.containerReaderDeclared === true;
  facts.uiDesignKitDeclared = declarations.uiDesignKitDeclared === true;
  facts.multiWindowDeclared = declarations.multiWindowDeclared === true;
  facts.keyboardShortcutDeclared = declarations.keyboardShortcutDeclared === true;
  facts.highContrast = declarations.highContrast === true;
  facts.reduceMotion = declarations.reduceMotion === true;
  facts.lowPowerMode = declarations.lowPowerMode === true;
  facts.terminalHighOutput = declarations.terminalHighOutput === true;
  return facts;
}
