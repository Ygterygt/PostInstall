@{
    # CI gates on Error severity; Warnings are reported but do not fail the build yet (see docs/ROADMAP.md).
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',                       # UI/engine intentionally write coloured host output
        'PSUseApprovedVerbs',                          # Prune-/Clear- helpers kept for backwards compatibility
        'PSUseShouldProcessForStateChangingFunctions', # modules run unattended by the engine
        'PSUseSingularNouns',
        'PSAvoidUsingEmptyCatchBlock'                  # best-effort cleanup paths
    )
}
