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
      expect(before.tabs.length).assertEqual(1);
      expect(workspace.tabOrder[0]).assertEqual('tab-two');
      expect(workspace.tabs[1].pinned).assertTrue();
      workspace = reduceSshWorkspace(workspace, {
        kind: 'close_tab', tabId: 'tab-two', nowMs: 105
      }).snapshot;
      expect(workspace.tabs.length).assertEqual(1);
      expect(workspace.activeTabId).assertEqual('tab-one');
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
  });
}
