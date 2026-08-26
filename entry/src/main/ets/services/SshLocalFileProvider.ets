import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { deviceInfo } from '@kit.BasicServicesKit';
import { Environment, fileIo, fileShare, fileUri, picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  resolveSshLocalProviderPlan,
  resolveSshLocalProviderState,
  SshLocalProviderAuthorization,
  SshLocalProviderCapabilities,
  SshLocalProviderPlan,
  SshLocalProviderState
} from './SshLocalProviderPolicy';
import {
  DEFAULT_SSH_SFTP_BATCH_LIMITS,
  SshSftpBatchLimits,
  SshSftpTreeItem
} from './SshSftpBatchPolicy';
import { sshDiagnosticErrorCode } from './ssh/observability/SshDiagnosticPolicy';

const PROVIDER_PREFS: string = 'RemoteDesktopSshLocalProviderPrefs';
const AUTHORIZED_ROOT_URI_KEY: string = 'authorized_root_uri';
const AUTHORIZED_ROOT_LABEL_KEY: string = 'authorized_root_label';
const TRANSFER_BOX_DIR: string = 'ssh-transfer-box';
const FOLDER_SELECTION_SYSCAP: string = 'SystemCapability.FileManagement.UserFileService.FolderSelection';
const FOLDER_AUTHORIZATION_SYSCAP: string = 'SystemCapability.FileManagement.AppFileService.FolderAuthorization';
const FOLDER_OBTAIN_SYSCAP: string = 'SystemCapability.FileManagement.File.Environment.FolderObtain';
const USER_FILE_SYSCAP: string = 'SystemCapability.FileManagement.UserFileService';
const LOCAL_PROVIDER_LOG_DOMAIN: number = 0x0000;
const LOCAL_PROVIDER_LOG_TAG: string = 'SshLocalFileProvider';

export type SshLocalProviderRootKind = 'authorizedFolder' | 'transferBox';

export interface SshLocalFileEntry {
  name: string;
  uri: string;
  isDirectory: boolean;
  isSymbolicLink: boolean;
  isSpecialFile: boolean;
  mode: number;
  size: number;
  mtime: number;
}

export interface SshLocalFileKind {
  isDirectory: boolean;
  isSymbolicLink: boolean;
  isSpecialFile: boolean;
}

/** Prefer FileIO's type probes because provider-backed stats may omit POSIX type bits. */
export function resolveSshLocalFileKind(mode: number, directoryProbe: boolean,
  symbolicLinkProbe: boolean): SshLocalFileKind {
  const typeBits: number = mode & 0xF000;
  const isDirectory: boolean = directoryProbe || typeBits === 0x4000;
  const isSymbolicLink: boolean = symbolicLinkProbe || typeBits === 0xA000;
  const isSpecialFile: boolean = !isDirectory && !isSymbolicLink && mode > 0 && typeBits !== 0x8000;
  return { isDirectory, isSymbolicLink, isSpecialFile };
}

export interface SshLocalProviderSnapshot {
  plan: SshLocalProviderPlan;
  state: SshLocalProviderState;
  rootKind: SshLocalProviderRootKind;
  rootUri: string;
  rootPath: string;
  rootLabel: string;
  generation: number;
}

export interface SshLocalProviderCapabilityProbe {
  capabilities: SshLocalProviderCapabilities;
  plan: SshLocalProviderPlan;
}

function canUseSystemCapability(name: string): boolean {
  try {
    return canIUse(name);
  } catch (_err) {
    return false;
  }
}

/**
 * Probe runtime capabilities. Folder authorization is only stable on PC/2in1
 * windows; tablets expose the same capability names but reject persisted
 * folder grants with Operation not permitted, so they use the transfer box.
 */
export function probeSshLocalProviderCapabilities(): SshLocalProviderCapabilityProbe {
  let deviceType: string = 'unknown';
  try { deviceType = deviceInfo.deviceType; } catch (_err) { /* best effort */ }
  const supportsAuthorizedFolder: boolean = deviceType === 'pc' || deviceType === '2in1';
  const folderSelection: boolean = supportsAuthorizedFolder &&
    canUseSystemCapability(FOLDER_SELECTION_SYSCAP);
  const folderAuthorization: boolean = supportsAuthorizedFolder &&
    canUseSystemCapability(FOLDER_AUTHORIZATION_SYSCAP);
  const folderObtain: boolean = supportsAuthorizedFolder &&
    canUseSystemCapability(FOLDER_OBTAIN_SYSCAP);
  const pickerAvailable: boolean = canUseSystemCapability(USER_FILE_SYSCAP);
  const capabilities: SshLocalProviderCapabilities = {
    folderSelection,
    folderAuthorization,
    folderObtain,
    pickerImport: pickerAvailable,
    pickerExport: pickerAvailable,
    share: false,
    // PC/2in1 can provide stable UDMF FILE_URI grants to the bounded staging
    // adapter. Other device classes keep the fail-closed transfer-box path.
    externalDrag: supportsAuthorizedFolder
  };
  const plan: SshLocalProviderPlan = resolveSshLocalProviderPlan(capabilities);
  hilog.info(LOCAL_PROVIDER_LOG_DOMAIN, LOCAL_PROVIDER_LOG_TAG,
    '[SFTP-LOCAL-PROBE] deviceType=' + deviceType +
    ' folderSelection=' + folderSelection.toString() +
    ' folderAuthorization=' + folderAuthorization.toString() +
    ' folderObtain=' + folderObtain.toString() +
    ' picker=' + pickerAvailable.toString() + ' plan=' + plan.kind);
  return { capabilities, plan };
}

/**
 * API 23 local side adapter. URI grants are kept in this provider's own
 * preference namespace, never in the SFTP task store. File operations remain
 * asynchronous so callers can keep them outside ArkUI event callbacks.
 */
export class SshLocalFileProvider {
  private static instance: SshLocalFileProvider | null = null;
  private context: common.UIAbilityContext | null = null;
  private plan: SshLocalProviderPlan = resolveSshLocalProviderPlan({
    folderSelection: false,
    folderAuthorization: false,
    folderObtain: false,
    pickerImport: false,
    pickerExport: false,
    share: false,
    externalDrag: false
  });
  private state: SshLocalProviderState = 'unavailable';
  private authorization: SshLocalProviderAuthorization = 'unknown';
  private rootUri: string = '';
  private rootPath: string = '';
  private rootLabel: string = '';
  private generation: number = 0;

  /** Page and process-wide transfer engine must observe one authorization owner. */
  static getInstance(): SshLocalFileProvider {
    if (SshLocalFileProvider.instance === null) {
      SshLocalFileProvider.instance = new SshLocalFileProvider();
    }
    return SshLocalFileProvider.instance;
  }

  init(context: common.UIAbilityContext): void {
    if (this.context === context) { return; }
    this.context = context;
    const probe: SshLocalProviderCapabilityProbe = probeSshLocalProviderCapabilities();
    this.plan = probe.plan;
    this.authorization = 'unknown';
    this.rootUri = '';
    this.rootPath = '';
    this.rootLabel = '';
    this.generation++;
    this.state = resolveSshLocalProviderState(this.plan, this.authorization);
    hilog.info(LOCAL_PROVIDER_LOG_DOMAIN, LOCAL_PROVIDER_LOG_TAG,
      '[SFTP-LOCAL-INIT] generation=' + this.generation.toString() + ' plan=' + this.plan.kind +
      ' state=' + this.state);
  }

  snapshot(): SshLocalProviderSnapshot {
    return {
      plan: this.plan,
      state: this.state,
      rootKind: this.plan.kind === 'directory' ? 'authorizedFolder' : 'transferBox',
      rootUri: this.rootUri,
      rootPath: this.rootPath,
      rootLabel: this.rootLabel,
      generation: this.generation
    };
  }

  async restoreAuthorization(): Promise<SshLocalProviderSnapshot> {
    if (this.context === null || this.plan.kind !== 'directory') {
      this.state = resolveSshLocalProviderState(this.plan, this.authorization);
      return this.snapshot();
    }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: PROVIDER_PREFS });
      const storedUri: Object = prefs.getSync(AUTHORIZED_ROOT_URI_KEY, '');
      const storedLabel: Object = prefs.getSync(AUTHORIZED_ROOT_LABEL_KEY, '');
      if (typeof storedUri !== 'string' || (storedUri as string).trim().length === 0) {
        this.authorization = 'unknown';
        this.state = 'needsAuthorization';
        return this.snapshot();
      }
      const uri: string = (storedUri as string).trim();
      const policies: Array<fileShare.PolicyInfo> = [this.permissionPolicy(uri)];
      const persistent: Array<boolean> = await fileShare.checkPersistentPermission(policies);
      if (persistent.length === 0 || persistent[0] !== true) {
        this.authorization = 'revoked';
        this.state = 'needsAuthorization';
        return this.snapshot();
      }
      await fileShare.activatePermission(policies);
      const path: string = this.pathFromUri(uri);
      if (path.length === 0) { throw new Error('authorized folder URI has no local path'); }
      this.rootUri = uri;
      this.rootPath = path;
      this.rootLabel = typeof storedLabel === 'string' && (storedLabel as string).length > 0
        ? storedLabel as string : this.displayName(uri);
      this.authorization = 'granted';
      this.state = 'ready';
      this.generation++;
    } catch (err) {
      this.rootUri = '';
      this.rootPath = '';
      this.authorization = 'revoked';
      this.state = 'needsAuthorization';
      hilog.error(LOCAL_PROVIDER_LOG_DOMAIN, LOCAL_PROVIDER_LOG_TAG,
        '[SFTP-LOCAL-RESTORE] failed code=' + sshDiagnosticErrorCode(err));
    }
    return this.snapshot();
  }

  async chooseAuthorizedFolder(): Promise<SshLocalProviderSnapshot> {
    if (this.context === null || this.plan.kind !== 'directory' ||
      !this.plan.canPersistAuthorization) {
      this.state = this.plan.kind === 'none' ? 'unavailable' : 'needsAuthorization';
      return this.snapshot();
    }
    hilog.info(LOCAL_PROVIDER_LOG_DOMAIN, LOCAL_PROVIDER_LOG_TAG,
      '[SFTP-LOCAL-CHOOSE] start deviceType=' + deviceInfo.deviceType +
      ' plan=' + this.plan.kind + ' persist=' + this.plan.canPersistAuthorization.toString());
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.selectMode = picker.DocumentSelectMode.FOLDER;
      const uris: Array<string> = await new picker.DocumentViewPicker(this.context).select(options);
      hilog.info(LOCAL_PROVIDER_LOG_DOMAIN, LOCAL_PROVIDER_LOG_TAG,
        '[SFTP-LOCAL-CHOOSE] picker returned count=' + uris.length.toString());
      if (uris.length === 0 || uris[0].trim().length === 0) {
        hilog.warn(LOCAL_PROVIDER_LOG_DOMAIN, LOCAL_PROVIDER_LOG_TAG,
          '[SFTP-LOCAL-CHOOSE] picker returned no URI');
        return this.snapshot();
      }
      const uri: string = uris[0].trim();
      const policy: fileShare.PolicyInfo = this.permissionPolicy(uri);
      await fileShare.persistPermission([policy]);
      hilog.info(LOCAL_PROVIDER_LOG_DOMAIN, LOCAL_PROVIDER_LOG_TAG,
        '[SFTP-LOCAL-CHOOSE] persistPermission ok uriLength=' + uri.length.toString());
      await fileShare.activatePermission([policy]);
      hilog.info(LOCAL_PROVIDER_LOG_DOMAIN, LOCAL_PROVIDER_LOG_TAG,
        '[SFTP-LOCAL-CHOOSE] activatePermission ok');
      const path: string = this.pathFromUri(uri);
      hilog.info(LOCAL_PROVIDER_LOG_DOMAIN, LOCAL_PROVIDER_LOG_TAG,
        '[SFTP-LOCAL-CHOOSE] pathFromUri chars=' + path.length.toString());
      if (path.length === 0) { throw new Error('selected folder URI has no local path'); }
      const prefs = preferences.getPreferencesSync(this.context, { name: PROVIDER_PREFS });
      const label: string = this.displayName(uri);
      prefs.putSync(AUTHORIZED_ROOT_URI_KEY, uri);
      prefs.putSync(AUTHORIZED_ROOT_LABEL_KEY, label);
      await prefs.flush();
      this.rootUri = uri;
      this.rootPath = path;
      this.rootLabel = label;
      this.authorization = 'granted';
      this.state = 'ready';
      this.generation++;
      hilog.info(LOCAL_PROVIDER_LOG_DOMAIN, LOCAL_PROVIDER_LOG_TAG,
        '[SFTP-LOCAL-CHOOSE] ready generation=' + this.generation.toString());
    } catch (err) {
      this.authorization = 'revoked';
      this.state = 'needsAuthorization';
      hilog.error(LOCAL_PROVIDER_LOG_DOMAIN, LOCAL_PROVIDER_LOG_TAG,
        '[SFTP-LOCAL-CHOOSE] failed code=' + sshDiagnosticErrorCode(err));
    }
    return this.snapshot();
  }

  async revokeAuthorization(): Promise<SshLocalProviderSnapshot> {
    if (this.context !== null && this.rootUri.length > 0 && this.plan.kind === 'directory') {
      try { await fileShare.revokePermission([this.permissionPolicy(this.rootUri)]); } catch (_err) { /* best effort */ }
      try {
        const prefs = preferences.getPreferencesSync(this.context, { name: PROVIDER_PREFS });
        prefs.deleteSync(AUTHORIZED_ROOT_URI_KEY);
        prefs.deleteSync(AUTHORIZED_ROOT_LABEL_KEY);
        await prefs.flush();
      } catch (_err) { /* state remains fail-closed */ }
    }
    this.rootUri = '';
    this.rootPath = '';
    this.rootLabel = '';
    this.authorization = 'revoked';
    this.state = this.plan.kind === 'none' ? 'unavailable' :
      this.plan.kind === 'directory' ? 'needsAuthorization' : 'ready';
    this.generation++;
    return this.snapshot();
  }

  async transferBoxRoot(): Promise<string> {
    if (this.context === null) { return ''; }
    const root: string = this.context.filesDir + '/' + TRANSFER_BOX_DIR;
    try { await fileIo.mkdir(root, true); } catch (_err) { /* already exists or provider denied */ }
    return root;
  }

  async currentRoot(): Promise<string> {
    if (this.plan.kind === 'directory' && this.state !== 'ready') { return ''; }
    if (this.plan.kind === 'directory') { return this.rootPath; }
    if (this.plan.kind === 'transferBox') { return await this.transferBoxRoot(); }
    return '';
  }

  /** Public folders are opt-in and remain unavailable when the runtime lacks the syscap. */
  publicFolder(kind: 'download' | 'desktop' | 'documents'): string {
    if (!canUseSystemCapability(FOLDER_OBTAIN_SYSCAP)) { return ''; }
    try {
      if (kind === 'download') { return Environment.getUserDownloadDir(); }
      if (kind === 'desktop') { return Environment.getUserDesktopDir(); }
      return Environment.getUserDocumentDir();
    } catch (_err) {
      return '';
    }
  }

  async list(root: string = ''): Promise<SshLocalFileEntry[]> {
    const requested: string = root.trim().length > 0 ? root.trim() : await this.currentRoot();
    const base: string = this.pathFromUri(requested);
    if (base.length === 0) { return []; }
    const currentRoot: string = await this.currentRoot();
    if (currentRoot.length === 0 || !this.isWithinRoot(currentRoot, base)) { return []; }
    const names: Array<string> = await fileIo.listFile(base, { recursion: false });
    const result: SshLocalFileEntry[] = [];
    for (let index = 0; index < names.length; index++) {
      const name: string = names[index];
      const uri: string = this.join(base, name);
      try {
        const info = await fileIo.stat(uri);
        result.push(this.entryFromStat(name, uri, info));
      } catch (_err) {
        // A provider can revoke one child while the directory remains readable.
      }
    }
    return result;
  }

  async stat(uri: string): Promise<SshLocalFileEntry | null> {
    const target: string = this.pathFromUri(uri);
    const root: string = await this.currentRoot();
    if (target.length === 0 || root.length === 0 || !this.isWithinRoot(root, target)) { return null; }
    try {
      const info = await fileIo.stat(target);
      return this.entryFromStat(this.baseName(target), target, info);
    } catch (_err) {
      return null;
    }
  }

  /** Resolve a relative file path without leaving an authorized provider root. */
  async resolveRelative(root: string, relativePath: string): Promise<string | null> {
    const providerRoot: string = await this.currentRoot();
    const base: string = this.pathFromUri(root);
    if (providerRoot.length === 0 || base.length === 0 || !this.isWithinRoot(providerRoot, base)) {
      return null;
    }
    const raw: string = relativePath.replace(/\\/g, '/');
    if (raw.length === 0) { return base; }
    if (raw.startsWith('/')) { return null; }
    const parts: string[] = raw.split('/');
    let target: string = base;
    for (let index = 0; index < parts.length; index++) {
      const part: string = parts[index];
      if (part.length === 0 || part === '.') { continue; }
      if (part === '..') { return null; }
      const safePart: string = this.safeChildName(part);
      if (safePart.length === 0) { return null; }
      target = this.join(target, safePart);
    }
    return this.isWithinRoot(providerRoot, target) ? target : null;
  }

  async createDirectory(parent: string, name: string): Promise<boolean> {
    const root: string = await this.currentRoot();
    const safeName: string = this.safeChildName(name);
    const base: string = parent.trim().length > 0 ? this.pathFromUri(parent) : root;
    if (root.length === 0 || safeName.length === 0 || !this.isWithinRoot(root, base)) { return false; }
    const target: string = this.join(base, safeName);
    if (!this.isWithinRoot(root, target)) { return false; }
    try {
      await fileIo.mkdir(target, false);
      return true;
    } catch (_err) {
      return false;
    }
  }

  async rename(uri: string, newName: string): Promise<boolean> {
    const root: string = await this.currentRoot();
    const source: string = this.pathFromUri(uri);
    const safeName: string = this.safeChildName(newName);
    if (root.length === 0 || source.length === 0 || safeName.length === 0 ||
      !this.isWithinRoot(root, source) || source === root) { return false; }
    const parent: string = this.parentPath(source);
    const target: string = this.join(parent, safeName);
    if (!this.isWithinRoot(root, target)) { return false; }
    try {
      await fileIo.rename(source, target);
      return true;
    } catch (_err) {
      return false;
    }
  }

  async remove(uri: string, recursive: boolean = false): Promise<boolean> {
    const root: string = await this.currentRoot();
    const target: string = this.pathFromUri(uri);
    if (root.length === 0 || target.length === 0 || target === root ||
      !this.isWithinRoot(root, target)) { return false; }
    const entry: SshLocalFileEntry | null = await this.stat(target);
    if (entry === null || entry.isSpecialFile) { return false; }
    try {
      if (!entry.isDirectory || entry.isSymbolicLink) {
        await fileIo.unlink(target);
        return true;
      }
      if (!recursive) {
        await fileIo.rmdir(target);
        return true;
      }
      const children: SshLocalFileEntry[] = await this.list(target);
      for (let index = 0; index < children.length; index++) {
        if (!await this.remove(children[index].uri, true)) { return false; }
      }
      await fileIo.rmdir(target);
      return true;
    } catch (_err) {
      return false;
    }
  }

  /** Flatten a local directory without following links or crossing the root. */
  async walk(root: string = '', limits: SshSftpBatchLimits = DEFAULT_SSH_SFTP_BATCH_LIMITS):
    Promise<SshSftpTreeItem[]> {
    const base: string = root.trim().length > 0 ? root.trim() : await this.currentRoot();
    const providerRoot: string = await this.currentRoot();
    if (base.length === 0 || providerRoot.length === 0 || !this.isWithinRoot(providerRoot, base)) {
      return [];
    }
    const result: SshSftpTreeItem[] = [];
    const visit = async (directory: string, relativeDirectory: string, depth: number): Promise<boolean> => {
      if (depth > limits.maxDepth) { return false; }
      const entries: SshLocalFileEntry[] = await this.list(directory);
      for (let index = 0; index < entries.length; index++) {
        const entry: SshLocalFileEntry = entries[index];
        const relativePath: string = relativeDirectory.length === 0
          ? entry.name : relativeDirectory + '/' + entry.name;
        const treeItem: SshSftpTreeItem = {
          relativePath,
          name: entry.name,
          isDirectory: entry.isDirectory,
          isSymbolicLink: entry.isSymbolicLink,
          isSpecialFile: entry.isSpecialFile,
          size: entry.size,
          mtime: entry.mtime,
          mode: entry.mode,
          uid: -1,
          gid: -1
        };
        result.push(treeItem);
        if (result.length > limits.maxItems) { return false; }
        if (entry.isDirectory && !entry.isSymbolicLink) {
          if (!await visit(entry.uri, relativePath, depth + 1)) { return false; }
        }
      }
      return true;
    };
    if (!await visit(base, '', 0)) { return []; }
    return result;
  }

  async chooseFiles(maxSelectNumber: number = 1): Promise<Array<string>> {
    if (!this.plan.canImport || this.context === null) { return []; }
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = Math.max(1, Math.min(500, maxSelectNumber));
    return await new picker.DocumentViewPicker(this.context).select(options);
  }

  async chooseSave(fileName: string): Promise<Array<string>> {
    if (!this.plan.canExport || this.context === null) { return []; }
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [this.safeFileName(fileName)];
    return await new picker.DocumentViewPicker(this.context).save(options);
  }

  private permissionPolicy(uri: string): fileShare.PolicyInfo {
    const mode: number = fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE |
      fileShare.OperationMode.CREATE_MODE | fileShare.OperationMode.DELETE_MODE |
      fileShare.OperationMode.RENAME_MODE;
    return { uri, operationMode: mode };
  }

  private displayName(uri: string): string {
    const normalized: string = uri.replace(/\\/g, '/').replace(/\/$/, '');
    const slash: number = normalized.lastIndexOf('/');
    return slash >= 0 && slash < normalized.length - 1 ? normalized.substring(slash + 1) : '已授权目录';
  }

  private safeFileName(fileName: string): string {
    const cleaned: string = fileName.replace(/[\\/:*?"<>|]/g, '_').trim();
    return cleaned.length > 0 ? cleaned.substring(0, 255) : 'download.bin';
  }

  /** Picker returns a persisted URI; FileIO directory APIs require its path. */
  private pathFromUri(value: string): string {
    const trimmed: string = value.trim();
    if (trimmed.length === 0) { return ''; }
    if (trimmed.indexOf('://') < 0) { return trimmed; }
    try {
      return new fileUri.FileUri(trimmed).path.trim();
    } catch (_err) {
      return '';
    }
  }

  private join(base: string, name: string): string {
    return base.endsWith('/') ? base + name : base + '/' + name;
  }

  private entryFromStat(name: string, uri: string, info: fileIo.Stat): SshLocalFileEntry {
    const mode: number = typeof info.mode === 'number' ? info.mode : 0;
    let directoryProbe: boolean = false;
    let symbolicLinkProbe: boolean = false;
    try { directoryProbe = info.isDirectory(); } catch (_err) { /* mode fallback */ }
    try { symbolicLinkProbe = info.isSymbolicLink(); } catch (_err) { /* mode fallback */ }
    const kind: SshLocalFileKind = resolveSshLocalFileKind(mode, directoryProbe, symbolicLinkProbe);
    const size: number = typeof info.size === 'number' ? info.size : -1;
    const mtime: number = typeof info.mtime === 'number' ? info.mtime : -1;
    return {
      name,
      uri,
      isDirectory: kind.isDirectory,
      isSymbolicLink: kind.isSymbolicLink,
      isSpecialFile: kind.isSpecialFile,
      mode,
      size: Number.isFinite(size) && size >= 0 ? size : -1,
      mtime: Number.isFinite(mtime) && mtime >= 0 ? mtime : -1
    };
  }

  private safeChildName(name: string): string {
    const trimmed: string = name.trim();
    if (trimmed.length === 0 || trimmed === '.' || trimmed === '..' ||
      trimmed.indexOf('/') >= 0 || trimmed.indexOf('\\') >= 0 || trimmed.indexOf('\0') >= 0) {
      return '';
    }
    return trimmed.substring(0, 255);
  }

  private normalizedPath(path: string): string {
    return path.replace(/\\/g, '/').replace(/\/+$/g, '');
  }

  private isWithinRoot(root: string, target: string): boolean {
    const normalizedRoot: string = this.normalizedPath(root);
    const normalizedTarget: string = this.normalizedPath(target);
    return normalizedTarget === normalizedRoot || normalizedTarget.startsWith(normalizedRoot + '/');
  }

  private parentPath(path: string): string {
    const normalized: string = this.normalizedPath(path);
    const slash: number = normalized.lastIndexOf('/');
    return slash > 0 ? normalized.substring(0, slash) : normalized;
  }

  private baseName(path: string): string {
    const normalized: string = this.normalizedPath(path);
    const slash: number = normalized.lastIndexOf('/');
    return slash >= 0 ? normalized.substring(slash + 1) : normalized;
  }
}
