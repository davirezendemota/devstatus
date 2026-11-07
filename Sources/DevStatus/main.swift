import Foundation

// Com subcomando (devstatus ai, agent...) roda no terminal; sem, abre o app de barra de menu.
if CLI.wants(CommandLine.arguments) {
    CLI.main()
} else {
    DevStatusApp.main()
}
