export interface MoonlightFeatureInputs {
  brandAssetProvenanceReady: boolean;
  hostControlImplementationReady: boolean;
  streamingImplementationReady: boolean;
  cloudSchemaDeployedAllEnvironments: boolean;
  remoteCryptoLifecycleReady: boolean;
  identityThreatModelApproved: boolean;
  hostControlCapabilityReady: boolean;
  streamingCapabilityReady: boolean;
  dataLifecycleReady: boolean;
  sessionLifecycleReady: boolean;
  releaseGateReady: boolean;
}

export interface MoonlightFeatureSnapshot {
  moonlightBrandAssetReady: boolean;
  moonlightHostControlReady: boolean;
  moonlightStreamingReady: boolean;
  moonlightCloudSchemaReady: boolean;
  moonlightCloudIdentityReady: boolean;
  moonlightProtocolAvailable: boolean;
}

export function defaultMoonlightFeatureInputs(): MoonlightFeatureInputs {
  return {
    brandAssetProvenanceReady: false,
    hostControlImplementationReady: false,
    streamingImplementationReady: false,
    cloudSchemaDeployedAllEnvironments: false,
    remoteCryptoLifecycleReady: false,
    identityThreatModelApproved: false,
    hostControlCapabilityReady: false,
    streamingCapabilityReady: false,
    dataLifecycleReady: false,
    sessionLifecycleReady: false,
    releaseGateReady: false
  };
}

export function resolveMoonlightFeatureSnapshot(
  inputs: MoonlightFeatureInputs
): MoonlightFeatureSnapshot {
  const hostControlReady: boolean = inputs.hostControlImplementationReady &&
    inputs.hostControlCapabilityReady && inputs.dataLifecycleReady;
  const streamingReady: boolean = hostControlReady && inputs.streamingImplementationReady &&
    inputs.streamingCapabilityReady && inputs.sessionLifecycleReady;
  const cloudIdentityReady: boolean = inputs.cloudSchemaDeployedAllEnvironments &&
    inputs.remoteCryptoLifecycleReady && inputs.identityThreatModelApproved && inputs.dataLifecycleReady;
  return {
    moonlightBrandAssetReady: inputs.brandAssetProvenanceReady,
    moonlightHostControlReady: hostControlReady,
    moonlightStreamingReady: streamingReady,
    moonlightCloudSchemaReady: inputs.cloudSchemaDeployedAllEnvironments,
    moonlightCloudIdentityReady: cloudIdentityReady,
    moonlightProtocolAvailable: streamingReady && inputs.releaseGateReady
  };
}
