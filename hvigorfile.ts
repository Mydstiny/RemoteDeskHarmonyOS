import { hvigor } from '@ohos/hvigor';
import { appTasks, OhosAppContext, OhosHapContext, OhosPluginId } from '@ohos/hvigor-ohos-plugin';

// Keep release-only branch pruning in versioned build logic, not machine signing profiles.
hvigor.getRootNode().afterNodeEvaluate((node) => {
  const context = node.getContext(OhosPluginId.OHOS_APP_PLUGIN) as OhosAppContext;
  const profile = context.getBuildProfileOpt();
  for (const product of profile.app.products ?? []) {
    product.buildOption ??= {};
    product.buildOption.arkOptions ??= {};
    product.buildOption.arkOptions.branchElimination = true;
  }
  context.setBuildProfileOpt(profile);
});

hvigor.nodesEvaluated(() => {
  const entry = hvigor.getRootNode().getSubNodeByName('entry');
  if (!entry) { return; }
  const context = entry.getContext(OhosPluginId.OHOS_HAP_PLUGIN) as OhosHapContext;
  context.targets((target) => {
    if (context.getBuildMode() === 'release' && !target.getBuildOption().arkOptions?.branchElimination) {
      throw new Error('Release requires branchElimination for Pro debug authorization isolation.');
    }
  });
});

export default {
  system: appTasks,
  plugins: []
};
