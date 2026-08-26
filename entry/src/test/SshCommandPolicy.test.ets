import { describe, it, expect } from '@ohos/hypium';
import {
  buildSshCommandRegistry,
  canExecuteSshCommand,
  findSshCommand,
  matchesSshCommandExecutionFence,
  rankSshCommands,
  SshCommandCapabilities,
  SshCommandDescriptor,
  SshCommandExecutionFence,
  SshCommandHostRef,
  SshCommandSessionRef
} from '../main/ets/services/ssh/command/SshCommandPolicy';

function capabilities(): SshCommandCapabilities {
  return {
    searchAvailable: true,
    profileAvailable: true,
    sftpAvailable: true,
    transferCenterAvailable: true,
    forwardingAvailable: false,
    closeAvailable: true,
    activePinned: false
  };
}

function hosts(): Array<SshCommandHostRef> {
  return [
    { hostId: 'host-prod', label: 'Production', opened: true, available: true },
    { hostId: 'host-stage', label: 'Staging', opened: false, available: true }
  ];
}

function sessions(): Array<SshCommandSessionRef> {
  return [
    {
      tabId: 'host-prod', hostId: 'host-prod', label: 'Production',
      stateLabel: '已连接', active: true, pinned: true
    },
    {
      tabId: 'host-lab', hostId: 'host-lab', label: 'Lab',
      stateLabel: '恢复中', active: false, pinned: false
    }
  ];
}

export default function sshCommandPolicyTest(): void {
  describe('SshCommandPolicy', (): void => {
    it('builds_one_semantic_registry_for_actions_sessions_and_hosts', 0, (): void => {
      const registry: Array<SshCommandDescriptor> =
        buildSshCommandRegistry(hosts(), sessions(), capabilities());
      expect(findSshCommand(registry, 'ssh.action.search')?.action)
        .assertEqual('open_terminal_search');
      expect(findSshCommand(registry, 'ssh.session.activate.host-lab')?.targetId)
        .assertEqual('host-lab');
      expect(findSshCommand(registry, 'ssh.host.open.host-stage')?.category)
        .assertEqual('host');
      expect(findSshCommand(registry, 'ssh.action.close-tab')?.danger)
        .assertEqual('confirm');
      expect(findSshCommand(registry, 'ssh.action.transfer-center')?.action)
        .assertEqual('open_transfer_center');
    });

    it('ranks_exact_title_before_prefix_keyword_and_subtitle_deterministically', 0, (): void => {
      const registry: Array<SshCommandDescriptor> =
        buildSshCommandRegistry(hosts(), sessions(), capabilities());
      const first: Array<SshCommandDescriptor> = rankSshCommands(registry, 'Production', 20);
      const second: Array<SshCommandDescriptor> = rankSshCommands(registry, 'Production', 20);
      expect(first.length).assertEqual(2);
      expect(first[0].id).assertEqual('ssh.host.open.host-prod');
      expect(first[1].id).assertEqual('ssh.session.activate.host-prod');
      expect(JSON.stringify(first)).assertEqual(JSON.stringify(second));
      expect(rankSshCommands(registry, 'transfer', 20)[0].id).assertEqual('ssh.action.sftp');
    });

    it('keeps_unavailable_actions_visible_but_not_executable', 0, (): void => {
      const registry: Array<SshCommandDescriptor> =
        buildSshCommandRegistry(hosts(), sessions(), capabilities());
      const forwarding: SshCommandDescriptor | null =
        findSshCommand(registry, 'ssh.action.forwarding');
      expect(forwarding !== null).assertTrue();
      expect(forwarding!.enabled).assertFalse();
      expect(canExecuteSshCommand(forwarding)).assertFalse();
      expect(canExecuteSshCommand(findSshCommand(registry, 'ssh.action.search'))).assertTrue();
      expect(canExecuteSshCommand(null)).assertFalse();
    });

    it('never_places_host_addresses_or_credentials_in_registry_metadata', 0, (): void => {
      const registry: Array<SshCommandDescriptor> = buildSshCommandRegistry([
        { hostId: 'opaque-host-id', label: 'Private box', opened: false, available: true }
      ], [], capabilities());
      const encoded: string = JSON.stringify(registry);
      expect(encoded.indexOf('password')).assertEqual(-1);
      expect(encoded.indexOf('privateKey')).assertEqual(-1);
      expect(encoded.indexOf('user@')).assertEqual(-1);
      expect(encoded.indexOf('/private/')).assertEqual(-1);
    });

    it('bounds_large_results_while_preserving_twenty_tab_navigation', 0, (): void => {
      const manySessions: Array<SshCommandSessionRef> = [];
      for (let index: number = 0; index < 140; index++) {
        manySessions.push({
          tabId: 'tab-' + index.toString(),
          hostId: 'host-' + index.toString(),
          label: 'Session ' + index.toString(),
          stateLabel: '已连接',
          active: index === 0,
          pinned: false
        });
      }
      const registry: Array<SshCommandDescriptor> =
        buildSshCommandRegistry([], manySessions, capabilities());
      expect(rankSshCommands(registry, '', 500).length).assertEqual(120);
      expect(rankSshCommands(registry, 'Session', 20).length).assertEqual(20);
      expect(rankSshCommands(registry, 'Session 19', 20)[0].targetId).assertEqual('host-19');
    });

    it('rejects_a_queued_action_after_owner_flag_generation_or_modal_changes', 0, (): void => {
      const expected: SshCommandExecutionFence = {
        pageGeneration: 7, bindingGeneration: 11, hostId: 'host-prod',
        sessionGeneration: 3, workbenchEnabled: true, modalActive: false
      };
      expect(matchesSshCommandExecutionFence(expected, { ...expected })).assertTrue();
      expect(matchesSshCommandExecutionFence(expected,
        { ...expected, hostId: 'host-stage' })).assertFalse();
      expect(matchesSshCommandExecutionFence(expected,
        { ...expected, sessionGeneration: 4 })).assertFalse();
      expect(matchesSshCommandExecutionFence(expected,
        { ...expected, workbenchEnabled: false })).assertFalse();
      expect(matchesSshCommandExecutionFence(expected,
        { ...expected, modalActive: true })).assertFalse();
    });
  });
}
