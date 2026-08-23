import { describe, it, expect } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import {
  createEmptySshWorkspace,
  decodeSshWorkspaceSnapshots,
  encodeSshWorkspaceSnapshots,
  reduceSshWorkspace,
  SshWorkspaceAction,
  SshWorkspaceReduceResult,
  SshWorkspaceSnapshotV1,
  SshWorkspaceTabV1,
  sshWorkspaceVisiblePaneCount,
  validateSshWorkspaceSnapshot
} from '../main/ets/services/ssh/workspace/SshWorkspacePolicy';
import {
  defaultSshWorkspacePlatformFacts,
  resolveSshWorkspaceCapabilities,
  SshWorkspaceCapabilities,
  SshWorkspacePlatformFacts,
  SSH_WORKBENCH_V2_DEFAULT_ENABLED
} from '../main/ets/services/ssh/workspace/SshWorkspaceCapabilityPolicy';
import {
  defaultSshWorkspacePlatformDeclarations,
  probeSshWorkspacePlatformFacts
} from '../main/ets/services/ssh/workspace/SshWorkspacePlatformProbe';
import { sshTerminalSessionProfileScopeKey } from
  '../main/ets/services/ssh/profile/SshTerminalProfilePolicy';
import {
  setSshWorkspaceCapabilityPreferenceAdapterForTest,
  SshWorkspaceCapabilityPreferenceAdapter,
  SshWorkspaceCapabilityPreferenceRead,
  SshWorkspaceCapabilityStore
} from '../main/ets/services/ssh/workspace/SshWorkspaceCapabilityStore';
import {
  resolveSshLayout,
  sameSshLayoutSemantics,
  SshLayoutInput,
  SshLayoutResult
} from '../main/ets/services/ssh/workspace/SshLayoutPolicy';
import {
  resolveSshTerminalSemanticStyle,
  SshTerminalSemanticStyle
} from '../main/ets/services/ssh/workspace/SshTerminalStylePolicy';
import {
  SshWorkspaceRuntimeAdapter
} from '../main/ets/services/ssh/workspace/SshWorkspaceRuntimeAdapter';
import {
  SshWorkspacePersistencePort,
  SshWorkspaceRepository,
  SshWorkspaceStoredRow,
  SshWorkspaceStoredRowsResult
} from '../main/ets/services/ssh/workspace/SshWorkspaceStore';
import {
  reconcileSshWorkspaceRuntimeTabs,
  SshWorkspaceRuntimeTabProjection
} from '../main/ets/services/ssh/workspace/SshWorkspaceProjectionPolicy';
import {
  resolveSshWorkspacePaneLayout,
  sshWorkspaceHiddenTabIds,
  sshWorkspaceParentSplit,
  SshWorkspacePaneLayoutResult
} from '../main/ets/services/ssh/workspace/SshWorkspacePaneLayoutPolicy';

class MemorySshWorkspaceCapabilityPreferences
  implements SshWorkspaceCapabilityPreferenceAdapter {
  exists: boolean = false;
  value: Object = false;
  writeSucceeded: boolean = true;

  read(_context: common.Context): SshWorkspaceCapabilityPreferenceRead {
    return { ok: true, exists: this.exists, value: this.value };
  }

  write(_context: common.Context, enabled: boolean): boolean {
    if (!this.writeSucceeded) { return false; }
    this.exists = true;
    this.value = enabled;
    return true;
  }
}

class MemorySshWorkspacePersistence implements SshWorkspacePersistencePort {
  rows: Array<SshWorkspaceStoredRow> = [];
  failReplace: boolean = false;
  failRemove: boolean = false;
  failRead: boolean = false;

  readRows(): SshWorkspaceStoredRowsResult {
    if (this.failRead) { return { ok: false, rows: [] }; }
    return { ok: true, rows: this.rows.map((row: SshWorkspaceStoredRow): SshWorkspaceStoredRow => ({
      workspaceId: row.workspaceId,
      schemaVersion: row.schemaVersion,
      revision: row.revision,
      payload: row.payload,
      active: row.active,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt
    })) };
  }

  replace(row: SshWorkspaceStoredRow, expectedRevision: number): boolean {
    if (this.failReplace) { return false; }
    const index: number = this.rows.findIndex(
      (item: SshWorkspaceStoredRow): boolean => item.workspaceId === row.workspaceId);
    const currentRevision: number = index < 0 ? -1 : this.rows[index].revision;
    if (currentRevision !== expectedRevision) { return false; }
    if (row.active) {
      this.rows = this.rows.map((item: SshWorkspaceStoredRow): SshWorkspaceStoredRow => ({
        workspaceId: item.workspaceId,
        schemaVersion: item.schemaVersion,
        revision: item.revision,
        payload: item.payload,
        active: false,
        createdAt: item.createdAt,
        updatedAt: item.updatedAt
      }));
    }
    if (index < 0) { this.rows.push(row); }
    else { this.rows[index] = row; }
    return true;
  }

  remove(workspaceId: string, expectedRevision: number): boolean {
    if (this.failRemove) { return false; }
    const index: number = this.rows.findIndex(
      (item: SshWorkspaceStoredRow): boolean => item.workspaceId === workspaceId &&
        item.revision === expectedRevision);
    if (index < 0) { return false; }
    this.rows.splice(index, 1);
    return true;
  }
}

function storedWorkspaceRow(snapshot: SshWorkspaceSnapshotV1,
  active: boolean = false): SshWorkspaceStoredRow {
  return {
    workspaceId: snapshot.workspaceId,
    schemaVersion: snapshot.schemaVersion,
    revision: snapshot.revision,
    payload: encodeSshWorkspaceSnapshots([snapshot]),
    active,
    createdAt: snapshot.createdAt,
    updatedAt: snapshot.updatedAt
  };
}

function tab(id: string, hostId: string, kind: 'terminal' | 'sftp' = 'terminal'): SshWorkspaceTabV1 {
  return {
    tabId: id,
    kind,
    hostId,
    titleOverride: '',
    profileId: '',
    pinned: false
  };
}

function openedWorkspace(): SshWorkspaceSnapshotV1 {
  const empty: SshWorkspaceSnapshotV1 = createEmptySshWorkspace('ws-main', 'Main', 100);
  const opened: SshWorkspaceReduceResult = reduceSshWorkspace(empty, {
    kind: 'open_tab',
    tab: tab('tab-one', 'host-one'),
    paneId: 'pane-one',
    nowMs: 101
  });
  return opened.snapshot;
}

function layoutInput(engine: 'static' | 'dynamic_layout', widthVp: number): SshLayoutInput {
  return {
    widthVp,
    heightVp: 900,
    containerWidthVp: widthVp,
    desktop: true,
    pad: false,
    sidebarRequested: true,
    inspectorRequested: true,
    requestedPaneCount: 4,
    minimumTerminalPaneWidthVp: 360,
    engine
  };
}

export default function sshWorkspacePolicyTest(): void {
  describe('SshWorkspacePolicy', (): void => {
    it('feature_flag_should_default_to_legacy_page', 0, (): void => {
      const facts: SshWorkspacePlatformFacts = defaultSshWorkspacePlatformFacts();
      const capabilities: SshWorkspaceCapabilities = resolveSshWorkspaceCapabilities(facts);
      expect(SSH_WORKBENCH_V2_DEFAULT_ENABLED).assertFalse();
      expect(capabilities.workbenchEnabled).assertFalse();
      expect(capabilities.layoutEngine).assertEqual('static');
      expect(capabilities.chromeTreatment).assertEqual('solid');
    });

    it('ssh_feature_flag_should_not_enable_non_ssh_protocols', 0, (): void => {
      const protocols: Array<string> = ['rdp', 'vnc', 'rustdesk', 'moonlight'];
      for (let i: number = 0; i < protocols.length; i++) {
        const facts: SshWorkspacePlatformFacts = defaultSshWorkspacePlatformFacts();
        facts.protocol = protocols[i];
        facts.apiVersion = 26;
        facts.featureFlagEnabled = true;
        facts.dynamicLayoutDeclared = true;
        facts.containerReaderDeclared = true;
        facts.uiDesignKitDeclared = true;
        facts.multiWindowDeclared = true;
        facts.keyboardShortcutDeclared = true;
        const capabilities: SshWorkspaceCapabilities = resolveSshWorkspaceCapabilities(facts);
        expect(capabilities.workbenchEnabled).assertFalse();
        expect(capabilities.layoutEngine).assertEqual('static');
        expect(capabilities.containerEngine).assertEqual('window_breakpoint');
        expect(capabilities.chromeTreatment).assertEqual('solid');
        expect(capabilities.detachedWindowEnabled).assertFalse();
        expect(capabilities.keyboardShortcutEnabled).assertFalse();
        expect(capabilities.motionLevel).assertEqual('none');
      }
    });

    it('runtime_probe_should_not_promote_api26_from_version_alone', 0, (): void => {
      const facts: SshWorkspacePlatformFacts = probeSshWorkspacePlatformFacts(
        true, defaultSshWorkspacePlatformDeclarations());
      const capabilities: SshWorkspaceCapabilities = resolveSshWorkspaceCapabilities(facts);
      expect(facts.featureFlagEnabled).assertTrue();
      expect(facts.dynamicLayoutDeclared).assertFalse();
      expect(facts.containerReaderDeclared).assertFalse();
      expect(capabilities.layoutEngine).assertEqual('static');
      expect(capabilities.containerEngine).assertEqual('window_breakpoint');
      expect(capabilities.chromeTreatment).assertEqual('solid');
    });

    it('cold_direct_ssh_should_restore_durable_workbench_flag', 0, (): void => {
      const adapter: MemorySshWorkspaceCapabilityPreferences =
        new MemorySshWorkspaceCapabilityPreferences();
      adapter.exists = true;
      adapter.value = true;
      setSshWorkspaceCapabilityPreferenceAdapterForTest(adapter);
      const store: SshWorkspaceCapabilityStore = new SshWorkspaceCapabilityStore();
      const context: common.Context = undefined as common.Context;
      expect(store.load(context)).assertTrue();
      adapter.value = 'not-a-boolean';
      expect(store.load(context)).assertFalse();
      expect(store.save(context, true)).assertTrue();
      expect(adapter.value as boolean).assertTrue();
      setSshWorkspaceCapabilityPreferenceAdapterForTest(null);
    });

    it('session_profile_scope_should_change_with_session_generation', 0, (): void => {
      const first: string = sshTerminalSessionProfileScopeKey('host-a', 7);
      const reconnected: string = sshTerminalSessionProfileScopeKey('host-a', 8);
      expect(first).assertEqual('host-a:generation:7');
      expect(reconnected).assertEqual('host-a:generation:8');
      expect(first === reconnected).assertFalse();
      expect(sshTerminalSessionProfileScopeKey('host-a', 0)).assertEqual('');
    });

    it('unverified_api26_capabilities_should_fail_to_static_semantics', 0, (): void => {
      const facts: SshWorkspacePlatformFacts = defaultSshWorkspacePlatformFacts();
      facts.apiVersion = 26;
      facts.featureFlagEnabled = true;
      facts.dynamicLayoutDeclared = true;
      const capabilities: SshWorkspaceCapabilities = resolveSshWorkspaceCapabilities(facts);
      expect(capabilities.layoutEngine).assertEqual('dynamic_layout');
      expect(capabilities.containerEngine).assertEqual('window_breakpoint');
      expect(capabilities.chromeTreatment).assertEqual('solid');
    });

    it('static_and_dynamic_layout_should_keep_the_same_semantic_tree', 0, (): void => {
      const staticLayout: SshLayoutResult = resolveSshLayout(layoutInput('static', 1500));
      const dynamicLayout: SshLayoutResult = resolveSshLayout(layoutInput('dynamic_layout', 1500));
      expect(sameSshLayoutSemantics(staticLayout, dynamicLayout)).assertTrue();
      expect(staticLayout.semanticRegions.join('|')).assertEqual(
        'title_actions|sidebar|tab_strip|pane_host|status_bar');
      const drifted: SshLayoutResult = resolveSshLayout(layoutInput('dynamic_layout', 1500));
      drifted.titleHeightVp += 1;
      expect(sameSshLayoutSemantics(staticLayout, drifted)).assertFalse();
    });

    it('narrow_pc_window_should_collapse_without_clipping_hit_targets', 0, (): void => {
      const layout: SshLayoutResult = resolveSshLayout(layoutInput('static', 360));
      expect(layout.mode).assertEqual('sm');
      expect(layout.sidebarVisible).assertFalse();
      expect(layout.inspectorVisible).assertFalse();
      expect(layout.visiblePaneCount).assertEqual(1);
      expect(layout.controlHitSizeVp).assertEqual(48);
      expect(layout.mainWidthVp).assertEqual(360);
    });

    it('workspace_sidebar_should_default_wide_collapse_on_phone_and_persist_user_choice',
      0, (): void => {
        const workspace: SshWorkspaceSnapshotV1 =
          createEmptySshWorkspace('ws-sidebar', 'Sidebar', 100);
        expect(workspace.sidebarVisible).assertTrue();

        const wideInput: SshLayoutInput = layoutInput('static', 1500);
        wideInput.sidebarRequested = workspace.sidebarVisible;
        const wide: SshLayoutResult = resolveSshLayout(wideInput);
        expect(wide.sidebarVisible).assertTrue();
        expect(wide.sidebarWidthVp).assertEqual(320);
        expect(wide.mainWidthVp).assertEqual(1180);

        const phoneInput: SshLayoutInput = layoutInput('static', 420);
        phoneInput.sidebarRequested = workspace.sidebarVisible;
        const phone: SshLayoutResult = resolveSshLayout(phoneInput);
        expect(phone.sidebarVisible).assertFalse();
        expect(phone.mainWidthVp).assertEqual(420);

        const collapsed: SshWorkspaceReduceResult = reduceSshWorkspace(workspace, {
          kind: 'set_sidebar_visible', visible: false, nowMs: 101
        });
        expect(collapsed.changed).assertTrue();
        expect(collapsed.snapshot.sidebarVisible).assertFalse();
        const decoded: SshWorkspaceSnapshotV1 = decodeSshWorkspaceSnapshots(
          encodeSshWorkspaceSnapshots([collapsed.snapshot])).snapshots[0];
        expect(decoded.sidebarVisible).assertFalse();
      });

    it('workspace_inspector_should_preserve_preference_and_yield_to_main_content', 0, (): void => {
      const workspace: SshWorkspaceSnapshotV1 = openedWorkspace();
      expect(workspace.inspectorVisible).assertFalse();
      const requested: SshWorkspaceReduceResult = reduceSshWorkspace(workspace, {
        kind: 'set_inspector_visible', visible: true, nowMs: 108
      });
      expect(requested.changed).assertTrue();
      expect(requested.snapshot.inspectorVisible).assertTrue();
      const decoded: SshWorkspaceSnapshotV1 = decodeSshWorkspaceSnapshots(
        encodeSshWorkspaceSnapshots([requested.snapshot])).snapshots[0];
      expect(decoded.inspectorVisible).assertTrue();

      const tripleInput: SshLayoutInput = layoutInput('static', 1800);
      tripleInput.requestedPaneCount = 1;
      const triple: SshLayoutResult = resolveSshLayout(tripleInput);
      expect(triple.sidebarVisible).assertTrue();
      expect(triple.inspectorVisible).assertTrue();
      expect(triple.inspectorWidthVp).assertEqual(320);
      expect(triple.mainWidthVp).assertEqual(1160);
      expect(triple.semanticRegions.join('|')).assertEqual(
        'title_actions|sidebar|tab_strip|pane_host|inspector|status_bar');

      const constrainedInput: SshLayoutInput = layoutInput('static', 1500);
      constrainedInput.requestedPaneCount = 1;
      const constrained: SshLayoutResult = resolveSshLayout(constrainedInput);
      expect(constrained.sidebarVisible).assertTrue();
      expect(constrained.inspectorVisible).assertFalse();
      expect(constrained.mainWidthVp).assertEqual(1180);

      constrainedInput.sidebarRequested = false;
      const withoutSidebar: SshLayoutResult = resolveSshLayout(constrainedInput);
      expect(withoutSidebar.inspectorVisible).assertTrue();
      expect(withoutSidebar.mainWidthVp).assertEqual(1180);
    });

    it('xl_workspace_should_keep_four_readable_panes_with_sidebar_visible', 0, (): void => {
      const wideInput: SshLayoutInput = layoutInput('static', 1500);
      wideInput.inspectorRequested = false;
      const wide: SshLayoutResult = resolveSshLayout(wideInput);
      expect(wide.sidebarVisible).assertTrue();
      expect(wide.mainWidthVp).assertEqual(1180);
      expect(wide.maxPaneCount).assertEqual(4);
      expect(wide.visiblePaneCount).assertEqual(4);

      let workspace: SshWorkspaceSnapshotV1 = openedWorkspace();
      for (let index: number = 2; index <= 4; index++) {
        workspace = reduceSshWorkspace(workspace, {
          kind: 'open_tab', tab: tab('wide-tab-' + index.toString(),
            'wide-host-' + index.toString()), nowMs: 110 + index
        }).snapshot;
        workspace = reduceSshWorkspace(workspace, {
          kind: 'split_pane', paneId: index === 2 ? 'pane-one' :
            'wide-pane-' + (index - 1).toString(),
          splitNodeId: 'wide-split-' + index.toString(),
          newLeafId: 'wide-pane-' + index.toString(), tabId: 'tab-one',
          direction: index % 2 === 0 ? 'horizontal' : 'vertical', ratio: 0.5,
          nowMs: 120 + index
        }).snapshot;
      }
      const treeBefore: string = JSON.stringify(workspace.paneRoot);
      const projected: SshWorkspacePaneLayoutResult = resolveSshWorkspacePaneLayout(
        workspace, '', wide.maxPaneCount, wide.mainWidthVp, 900, 360);
      expect(projected.frames.length).assertEqual(4);
      for (let index: number = 0; index < projected.frames.length; index++) {
        expect(projected.frames[index].widthVp >= 360).assertTrue();
      }
      expect(JSON.stringify(workspace.paneRoot)).assertEqual(treeBefore);
    });

    it('terminal_surface_should_remain_opaque_and_reduce_effects', 0, (): void => {
      const facts: SshWorkspacePlatformFacts = defaultSshWorkspacePlatformFacts();
      facts.apiVersion = 26;
      facts.featureFlagEnabled = true;
      facts.uiDesignKitDeclared = true;
      const capabilities: SshWorkspaceCapabilities = resolveSshWorkspaceCapabilities(facts);
      const style: SshTerminalSemanticStyle = resolveSshTerminalSemanticStyle({
        theme: 'dark',
        density: 'compact',
        highContrast: false,
        reduceMotion: true,
        lowPowerMode: false,
        terminalHighOutput: false,
        capabilities
      });
      expect(style.terminalSurface).assertEqual('opaque');
      expect(style.motionLevel).assertEqual('none');
      expect(style.hitControlSizeVp).assertEqual(48);
    });

    it('open_tab_should_create_an_immutable_first_pane', 0, (): void => {
      const empty: SshWorkspaceSnapshotV1 = createEmptySshWorkspace('ws-main', 'Main', 100);
      const result: SshWorkspaceReduceResult = reduceSshWorkspace(empty, {
        kind: 'open_tab', tab: tab('tab-one', 'host-one'), paneId: 'pane-one', nowMs: 101
      });
      expect(result.changed).assertTrue();
      expect(empty.tabs.length).assertEqual(0);
      expect(result.snapshot.tabs.length).assertEqual(1);
      expect(result.snapshot.activePaneId).assertEqual('pane-one');
      expect(result.snapshot.reconnectPolicy).assertEqual('never');
      expect(validateSshWorkspaceSnapshot(result.snapshot).length).assertEqual(0);
    });

    it('split_move_focus_and_merge_should_preserve_valid_ownership', 0, (): void => {
      let workspace: SshWorkspaceSnapshotV1 = openedWorkspace();
      workspace = reduceSshWorkspace(workspace, {
        kind: 'open_tab', tab: tab('tab-two', 'host-two', 'sftp'), nowMs: 102
      }).snapshot;
      workspace = reduceSshWorkspace(workspace, {
        kind: 'split_pane', paneId: 'pane-one', splitNodeId: 'split-one',
        newLeafId: 'pane-two', tabId: 'tab-one', direction: 'horizontal', ratio: 0.95,
        nowMs: 103
      }).snapshot;
      expect(sshWorkspaceVisiblePaneCount(workspace.paneRoot)).assertEqual(2);
      expect(workspace.paneRoot?.ratio).assertEqual(0.8);
      workspace = reduceSshWorkspace(workspace, {
        kind: 'move_tab', tabId: 'tab-two', paneId: 'pane-two', nowMs: 104
      }).snapshot;
      expect(workspace.activePaneId).assertEqual('pane-two');
      expect(workspace.activeTabId).assertEqual('tab-two');
      workspace = reduceSshWorkspace(workspace, {
        kind: 'merge_pane', paneId: 'pane-two', nowMs: 105
      }).snapshot;
      expect(sshWorkspaceVisiblePaneCount(workspace.paneRoot)).assertEqual(1);
      expect(validateSshWorkspaceSnapshot(workspace).length).assertEqual(0);
    });

    it('tab_close_reorder_and_pin_should_not_mutate_previous_snapshot', 0, (): void => {
      let workspace: SshWorkspaceSnapshotV1 = openedWorkspace();
      const before: SshWorkspaceSnapshotV1 = workspace;
      workspace = reduceSshWorkspace(workspace, {
        kind: 'open_tab', tab: tab('tab-two', 'host-two'), nowMs: 102
      }).snapshot;
      workspace = reduceSshWorkspace(workspace, {
        kind: 'reorder_tab', tabId: 'tab-two', beforeTabId: 'tab-one', nowMs: 103
      }).snapshot;
      workspace = reduceSshWorkspace(workspace, {
        kind: 'set_tab_pinned', tabId: 'tab-two', pinned: true, nowMs: 104
      }).snapshot;
      workspace = reduceSshWorkspace(workspace, {
        kind: 'rename_tab', tabId: 'tab-two', title: '  Production shell  ', nowMs: 105
      }).snapshot;
      expect(before.tabs.length).assertEqual(1);
      expect(workspace.tabOrder[0]).assertEqual('tab-two');
      expect(workspace.tabs[1].pinned).assertTrue();
      expect(workspace.tabs[1].titleOverride).assertEqual('Production shell');
      workspace = reduceSshWorkspace(workspace, {
        kind: 'close_tab', tabId: 'tab-two', nowMs: 106
      }).snapshot;
      expect(workspace.tabs.length).assertEqual(1);
      expect(workspace.activeTabId).assertEqual('tab-one');
      expect(validateSshWorkspaceSnapshot(workspace).length).assertEqual(0);
    });

    it('twenty_tabs_should_remain_valid_and_ordered', 0, (): void => {
      let workspace: SshWorkspaceSnapshotV1 = openedWorkspace();
      for (let index: number = 2; index <= 20; index++) {
        workspace = reduceSshWorkspace(workspace, {
          kind: 'open_tab',
          tab: tab('tab-' + index.toString(), 'host-' + index.toString()),
          nowMs: 100 + index
        }).snapshot;
      }
      expect(workspace.tabs.length).assertEqual(20);
      expect(workspace.tabOrder.length).assertEqual(20);
      expect(workspace.tabOrder[19]).assertEqual('tab-20');
      expect(validateSshWorkspaceSnapshot(workspace).length).assertEqual(0);
    });

    it('pane_split_should_stop_at_four_visible_panes', 0, (): void => {
      let workspace: SshWorkspaceSnapshotV1 = openedWorkspace();
      workspace = reduceSshWorkspace(workspace, {
        kind: 'open_tab', tab: tab('tab-two', 'host-two'), nowMs: 102
      }).snapshot;
      workspace = reduceSshWorkspace(workspace, {
        kind: 'split_pane', paneId: 'pane-one', splitNodeId: 'split-one',
        newLeafId: 'pane-two', tabId: 'tab-one', direction: 'horizontal', ratio: 0.5
      }).snapshot;
      workspace = reduceSshWorkspace(workspace, {
        kind: 'open_tab', tab: tab('tab-three', 'host-three'), nowMs: 103
      }).snapshot;
      workspace = reduceSshWorkspace(workspace, {
        kind: 'split_pane', paneId: 'pane-one', splitNodeId: 'split-two',
        newLeafId: 'pane-three', tabId: 'tab-one', direction: 'vertical', ratio: 0.5
      }).snapshot;
      workspace = reduceSshWorkspace(workspace, {
        kind: 'open_tab', tab: tab('tab-four', 'host-four'), nowMs: 104
      }).snapshot;
      workspace = reduceSshWorkspace(workspace, {
        kind: 'split_pane', paneId: 'pane-two', splitNodeId: 'split-three',
        newLeafId: 'pane-four', tabId: 'tab-one', direction: 'horizontal', ratio: 0.5
      }).snapshot;
      workspace = reduceSshWorkspace(workspace, {
        kind: 'open_tab', tab: tab('tab-five', 'host-five'), nowMs: 105
      }).snapshot;
      const rejected: SshWorkspaceReduceResult = reduceSshWorkspace(workspace, {
        kind: 'split_pane', paneId: 'pane-three', splitNodeId: 'split-four',
        newLeafId: 'pane-five', tabId: 'tab-one', direction: 'vertical', ratio: 0.5
      });
      expect(sshWorkspaceVisiblePaneCount(workspace.paneRoot)).assertEqual(4);
      expect(rejected.changed).assertFalse();
      expect(rejected.error?.code).assertEqual('limit_reached');
    });

    it('split_pane_should_reject_non_finite_ratio_and_unknown_direction', 0, (): void => {
      let workspace: SshWorkspaceSnapshotV1 = openedWorkspace();
      workspace = reduceSshWorkspace(workspace, {
        kind: 'open_tab', tab: tab('tab-two', 'host-two'), nowMs: 102
      }).snapshot;
      const nanResult: SshWorkspaceReduceResult = reduceSshWorkspace(workspace, {
        kind: 'split_pane', paneId: 'pane-one', splitNodeId: 'split-one',
        newLeafId: 'pane-two', tabId: 'tab-one', direction: 'horizontal', ratio: Number.NaN
      });
      const invalidDirection: SshWorkspaceAction = JSON.parse(
        '{"kind":"split_pane","paneId":"pane-one","splitNodeId":"split-one",' +
        '"newLeafId":"pane-two","tabId":"tab-one","direction":"diagonal","ratio":0.5}') as
        SshWorkspaceAction;
      const directionResult: SshWorkspaceReduceResult =
        reduceSshWorkspace(workspace, invalidDirection);
      expect(nanResult.error?.code).assertEqual('invalid_action');
      expect(directionResult.error?.code).assertEqual('invalid_action');
      expect(nanResult.snapshot === workspace).assertTrue();
      expect(directionResult.snapshot === workspace).assertTrue();
      expect(sshWorkspaceVisiblePaneCount(workspace.paneRoot)).assertEqual(1);
    });

    it('decoder_should_isolate_bad_and_future_records', 0, (): void => {
      const workspace: SshWorkspaceSnapshotV1 = openedWorkspace();
      const raw: string = '{"schemaVersion":1,"items":[' + JSON.stringify(workspace) +
        ',{"schemaVersion":1,"workspaceId":42},' +
        '{"schemaVersion":2,"workspaceId":"future"}]}' ;
      const decoded = decodeSshWorkspaceSnapshots(raw);
      expect(decoded.snapshots.length).assertEqual(1);
      expect(decoded.rejected).assertEqual(1);
      expect(decoded.unsupported).assertEqual(1);
    });

    it('decoder_should_skip_one_bad_tab_without_clearing_valid_tabs', 0, (): void => {
      const workspace: SshWorkspaceSnapshotV1 = openedWorkspace();
      const clean: string = JSON.stringify(workspace);
      const contaminated: string = clean.replace('"tabs":[', '"tabs":[{"tabId":42},');
      const raw: string = '{"schemaVersion":1,"items":[' + contaminated + ']}';
      const decoded = decodeSshWorkspaceSnapshots(raw);
      expect(decoded.snapshots.length).assertEqual(1);
      expect(decoded.snapshots[0].tabs.length).assertEqual(1);
      expect(decoded.snapshots[0].tabs[0].tabId).assertEqual('tab-one');
    });

    it('decoder_should_repair_split_empty_and_mismatched_active_ids', 0, (): void => {
      let workspace: SshWorkspaceSnapshotV1 = openedWorkspace();
      workspace = reduceSshWorkspace(workspace, {
        kind: 'open_tab', tab: tab('tab-two', 'host-two'), nowMs: 102
      }).snapshot;
      workspace = reduceSshWorkspace(workspace, {
        kind: 'split_pane', paneId: 'pane-one', splitNodeId: 'split-one',
        newLeafId: 'pane-two', tabId: 'tab-one', direction: 'horizontal', ratio: 0.5
      }).snapshot;
      const splitActive: SshWorkspaceSnapshotV1 = JSON.parse(JSON.stringify(workspace)) as
        SshWorkspaceSnapshotV1;
      splitActive.workspaceId = 'ws-split';
      splitActive.activePaneId = 'split-one';
      splitActive.activeTabId = 'tab-one';
      const emptyActive: SshWorkspaceSnapshotV1 = JSON.parse(JSON.stringify(workspace)) as
        SshWorkspaceSnapshotV1;
      emptyActive.workspaceId = 'ws-empty';
      emptyActive.activePaneId = '';
      emptyActive.activeTabId = '';
      const mismatched: SshWorkspaceSnapshotV1 = JSON.parse(JSON.stringify(workspace)) as
        SshWorkspaceSnapshotV1;
      mismatched.workspaceId = 'ws-mismatch';
      mismatched.activePaneId = 'pane-two';
      mismatched.activeTabId = 'tab-two';
      const raw: string = '{"schemaVersion":1,"items":[' + JSON.stringify(splitActive) + ',' +
        JSON.stringify(emptyActive) + ',' + JSON.stringify(mismatched) + ']}';
      const decoded = decodeSshWorkspaceSnapshots(raw);
      expect(decoded.snapshots.length).assertEqual(3);
      expect(decoded.snapshots[0].activePaneId).assertEqual('pane-one');
      expect(decoded.snapshots[0].activeTabId).assertEqual('tab-two');
      expect(decoded.snapshots[1].activePaneId).assertEqual('pane-one');
      expect(decoded.snapshots[1].activeTabId).assertEqual('tab-two');
      expect(decoded.snapshots[2].activePaneId).assertEqual('pane-two');
      expect(decoded.snapshots[2].activeTabId).assertEqual('tab-one');
      const rejected: SshWorkspaceReduceResult = reduceSshWorkspace(splitActive, {
        kind: 'rename_workspace', name: 'Rejected'
      });
      expect(rejected.error?.code).assertEqual('invalid_snapshot');
      expect(rejected.snapshot === splitActive).assertTrue();
    });

    it('generated_pane_ids_should_stay_valid_for_maximum_workspace_id', 0, (): void => {
      const workspaceId: string = 'w'.repeat(96);
      let workspace: SshWorkspaceSnapshotV1 = createEmptySshWorkspace(workspaceId, 'Long', 100);
      workspace = reduceSshWorkspace(workspace, {
        kind: 'open_tab', tab: tab('tab-one', 'host-one'), paneId: 'pane-one', nowMs: 101
      }).snapshot;
      workspace = reduceSshWorkspace(workspace, {
        kind: 'open_tab', tab: tab('tab-two', 'host-two'), nowMs: 102
      }).snapshot;
      const hiddenClosed: SshWorkspaceReduceResult = reduceSshWorkspace(workspace, {
        kind: 'close_tab', tabId: 'tab-one', nowMs: 103
      });
      expect(validateSshWorkspaceSnapshot(hiddenClosed.snapshot).length).assertEqual(0);
      const visibleClosed: SshWorkspaceReduceResult = reduceSshWorkspace(workspace, {
        kind: 'close_tab', tabId: 'tab-two', nowMs: 103
      });
      expect(visibleClosed.snapshot.paneRoot?.nodeId.length).assertLarger(0);
      expect((visibleClosed.snapshot.paneRoot?.nodeId.length ?? 97) <= 96).assertTrue();
      expect(validateSshWorkspaceSnapshot(visibleClosed.snapshot).length).assertEqual(0);
      const fallbackSource: SshWorkspaceSnapshotV1 = JSON.parse(JSON.stringify(workspace)) as
        SshWorkspaceSnapshotV1;
      fallbackSource.paneRoot = null;
      fallbackSource.activePaneId = '';
      fallbackSource.activeTabId = '';
      const decoded = decodeSshWorkspaceSnapshots(
        '{"schemaVersion":1,"items":[' + JSON.stringify(fallbackSource) + ']}');
      expect(decoded.snapshots.length).assertEqual(1);
      expect((decoded.snapshots[0].paneRoot?.nodeId.length ?? 97) <= 96).assertTrue();
    });

    it('encoded_snapshot_should_not_contain_runtime_or_secret_fields', 0, (): void => {
      const clean: string = JSON.stringify(openedWorkspace());
      const contaminated: string = clean
        .replace('"workspaceId":', '"password":"secret","sessionId":99,' +
          '"terminalOutput":"raw","cwdHint":"/tmp","autoConnect":true,"workspaceId":')
        .replace('"tabId":"tab-one"', '"path":"/private/key","privateKey":"pem","tabId":"tab-one"');
      const decoded = decodeSshWorkspaceSnapshots(
        '{"schemaVersion":1,"items":[' + contaminated + ']}');
      expect(decoded.snapshots.length).assertEqual(1);
      const encoded: string = encodeSshWorkspaceSnapshots(decoded.snapshots);
      expect(encoded.indexOf('password')).assertEqual(-1);
      expect(encoded.indexOf('privateKey')).assertEqual(-1);
      expect(encoded.indexOf('sessionId')).assertEqual(-1);
      expect(encoded.indexOf('terminalOutput')).assertEqual(-1);
      expect(encoded.indexOf('"path"')).assertEqual(-1);
      expect(encoded.indexOf('cwdHint')).assertEqual(-1);
      expect(encoded.indexOf('autoConnect')).assertEqual(-1);
    });

    it('runtime_adapter_should_reject_stale_generation_without_owning_teardown', 0, (): void => {
      const adapter: SshWorkspaceRuntimeAdapter = new SshWorkspaceRuntimeAdapter();
      expect(adapter.bind('tab-one', 'host-one', {
        sessionId: 7, channelId: 'shell', generation: 2
      }).accepted).assertTrue();
      expect(adapter.accepts('tab-one', {
        sessionId: 7, channelId: 'shell', generation: 1
      })).assertFalse();
      expect(adapter.bind('tab-one', 'host-one', {
        sessionId: 7, channelId: 'shell', generation: 1
      }).accepted).assertFalse();
      expect(adapter.bind('tab-one', 'host-one', {
        sessionId: 8, channelId: 'shell', generation: 3
      }).accepted).assertTrue();
      expect(adapter.bind('tab-one', 'host-one', {
        sessionId: 9, channelId: 'shell', generation: 3
      }).accepted).assertFalse();
      expect(adapter.detachIfCurrent('tab-one', {
        sessionId: 7, channelId: 'shell', generation: 2
      })).assertNull();
      expect(adapter.size()).assertEqual(1);
      expect(adapter.detachIfCurrent('tab-one', {
        sessionId: 8, channelId: 'shell', generation: 3
      })?.sessionId).assertEqual(8);
      expect(adapter.size()).assertEqual(0);
    });

    it('workspace_repository_should_isolate_corrupt_and_future_rdb_rows', 0, (): void => {
      const valid: SshWorkspaceSnapshotV1 = openedWorkspace();
      const future: SshWorkspaceStoredRow = storedWorkspaceRow(valid);
      future.workspaceId = 'ws-future';
      future.schemaVersion = 2;
      const corrupt: SshWorkspaceStoredRow = storedWorkspaceRow(valid);
      corrupt.workspaceId = 'ws-corrupt';
      corrupt.payload = '{broken';
      const persistence: MemorySshWorkspacePersistence = new MemorySshWorkspacePersistence();
      persistence.rows = [storedWorkspaceRow(valid, true), future, corrupt];
      const repository: SshWorkspaceRepository = new SshWorkspaceRepository(persistence);
      const restored = repository.restore();
      expect(restored.snapshots.length).assertEqual(1);
      expect(restored.readable).assertTrue();
      expect(restored.activeWorkspaceId).assertEqual(valid.workspaceId);
      expect(restored.rejected).assertEqual(1);
      expect(restored.unsupported).assertEqual(1);
      expect(restored.snapshots[0].reconnectPolicy).assertEqual('never');
      expect(repository.durableRevision(valid.workspaceId)).assertEqual(valid.revision);
    });

    it('workspace_repository_should_fail_closed_when_rdb_read_fails', 0, (): void => {
      const persistence: MemorySshWorkspacePersistence = new MemorySshWorkspacePersistence();
      persistence.rows = [storedWorkspaceRow(openedWorkspace(), true)];
      persistence.failRead = true;
      const repository: SshWorkspaceRepository = new SshWorkspaceRepository(persistence);
      const restored = repository.restore();
      expect(restored.readable).assertFalse();
      expect(restored.snapshots.length).assertEqual(0);
      expect(restored.activeWorkspaceId).assertEqual('');
    });

    it('workspace_repository_should_keep_last_durable_snapshot_on_write_failure', 0, (): void => {
      const first: SshWorkspaceSnapshotV1 = openedWorkspace();
      const persistence: MemorySshWorkspacePersistence = new MemorySshWorkspacePersistence();
      persistence.rows = [storedWorkspaceRow(first, true)];
      const repository: SshWorkspaceRepository = new SshWorkspaceRepository(persistence);
      repository.restore();
      const renamed: SshWorkspaceReduceResult = reduceSshWorkspace(first, {
        kind: 'rename_workspace', name: 'Durable after retry', nowMs: 200
      });
      persistence.failReplace = true;
      const failed = repository.save(renamed.snapshot, true);
      expect(failed.ok).assertFalse();
      expect(failed.code).assertEqual('write_failed');
      expect(repository.durableRevision(first.workspaceId)).assertEqual(first.revision);
      expect(persistence.rows[0].payload).assertEqual(encodeSshWorkspaceSnapshots([first]));
      persistence.failReplace = false;
      const retried = repository.save(renamed.snapshot, true);
      expect(retried.ok).assertTrue();
      expect(retried.durableRevision).assertEqual(renamed.snapshot.revision);
      const stale = repository.save(first, true);
      expect(stale.ok).assertFalse();
      expect(stale.code).assertEqual('stale_revision');
    });

    it('workspace_repository_should_reject_divergent_payload_at_same_revision', 0,
      (): void => {
        const first: SshWorkspaceSnapshotV1 = openedWorkspace();
        const persistence: MemorySshWorkspacePersistence = new MemorySshWorkspacePersistence();
        persistence.rows = [storedWorkspaceRow(first, true)];
        const repository: SshWorkspaceRepository = new SshWorkspaceRepository(persistence);
        repository.restore();
        const editorA: SshWorkspaceSnapshotV1 = reduceSshWorkspace(first, {
          kind: 'rename_workspace', name: 'Editor A', nowMs: 200
        }).snapshot;
        const editorB: SshWorkspaceSnapshotV1 = reduceSshWorkspace(first, {
          kind: 'rename_workspace', name: 'Editor B', nowMs: 201
        }).snapshot;
        expect(editorA.revision).assertEqual(editorB.revision);
        expect(repository.save(editorA, true).ok).assertTrue();
        const conflict = repository.save(editorB, true);
        expect(conflict.ok).assertFalse();
        expect(conflict.code).assertEqual('stale_revision');
        expect(persistence.rows[0].payload).assertEqual(encodeSshWorkspaceSnapshots([editorA]));
      });

    it('runtime_projection_should_preserve_restored_placeholders_without_auto_connect', 0,
      (): void => {
        let restored: SshWorkspaceSnapshotV1 = openedWorkspace();
        restored = reduceSshWorkspace(restored, {
          kind: 'open_tab', tab: tab('tab-restored', 'host-restored'), nowMs: 102
        }).snapshot;
        const runtimeTabs: Array<SshWorkspaceRuntimeTabProjection> = [{
          tabId: 'tab-live', hostId: 'host-live', title: 'Live', profileId: '',
          pinned: false, active: true
        }];
        const reconciled: SshWorkspaceSnapshotV1 = reconcileSshWorkspaceRuntimeTabs(
          restored, runtimeTabs, 'host-live', 200);
        expect(reconciled.tabs.length).assertEqual(3);
        expect(reconciled.tabs.find((item: SshWorkspaceTabV1): boolean =>
          item.tabId === 'tab-restored') !== undefined).assertTrue();
        expect(reconciled.activeTabId).assertEqual('tab-live');
        expect(reconciled.reconnectPolicy).assertEqual('never');
        expect(validateSshWorkspaceSnapshot(reconciled).length).assertEqual(0);
      });

    it('pane_projection_should_keep_four_pane_tree_stable_across_breakpoints', 0, (): void => {
      let workspace: SshWorkspaceSnapshotV1 = openedWorkspace();
      for (let index: number = 2; index <= 4; index++) {
        workspace = reduceSshWorkspace(workspace, {
          kind: 'open_tab', tab: tab('tab-' + index.toString(), 'host-' + index.toString()),
          nowMs: 100 + index
        }).snapshot;
        workspace = reduceSshWorkspace(workspace, {
          kind: 'split_pane', paneId: index === 2 ? 'pane-one' : 'pane-' + (index - 1).toString(),
          splitNodeId: 'split-' + index.toString(),
          newLeafId: 'pane-' + index.toString(), tabId: 'tab-one',
          direction: index % 2 === 0 ? 'horizontal' : 'vertical', ratio: 0.5,
          nowMs: 110 + index
        }).snapshot;
      }
      const treeBefore: string = JSON.stringify(workspace.paneRoot);
      const wide: SshWorkspacePaneLayoutResult = resolveSshWorkspacePaneLayout(
        workspace, '', 4, 1600, 900);
      const narrow: SshWorkspacePaneLayoutResult = resolveSshWorkspacePaneLayout(
        workspace, '', 1, 360, 700);
      const focused: SshWorkspacePaneLayoutResult = resolveSshWorkspacePaneLayout(
        workspace, workspace.activePaneId, 4, 1600, 900);
      expect(wide.frames.length).assertEqual(4);
      expect(narrow.frames.length).assertEqual(1);
      expect(narrow.frames[0].paneId).assertEqual(workspace.activePaneId);
      expect(focused.frames.length).assertEqual(1);
      expect(focused.focused).assertTrue();
      expect(JSON.stringify(workspace.paneRoot)).assertEqual(treeBefore);
      expect(sshWorkspaceHiddenTabIds(workspace).length).assertEqual(0);
      expect(sshWorkspaceParentSplit(workspace.paneRoot, workspace.activePaneId) !== null)
        .assertTrue();
    });
  });
}
