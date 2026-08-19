/**
 * Behavior-neutral migration shell. It is intentionally not wired into
 * SshTerminal while sshWorkbenchV2 is disabled by default.
 */
@Component
export struct SshWorkspaceShell {
  @Prop enabled: boolean = false;

  @Builder
  private emptyContent() {
  }

  @BuilderParam legacyContent: () => void = this.emptyContent;
  @BuilderParam workspaceContent: () => void = this.emptyContent;

  build() {
    Stack() {
      if (this.enabled) {
        this.workspaceContent();
      } else {
        this.legacyContent();
      }
    }
    .width('100%')
    .height('100%')
  }
}
